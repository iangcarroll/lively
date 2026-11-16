import SwiftUI

/// Keeps conversation text inside its own viewport while controls and guidance
/// reserve space, including as the keyboard or listening reminder appears.
struct ConversationTranscriptLayout<Header: View, Transcript: View, Footer: View>: View {
    private let header: Header
    private let transcript: Transcript
    private let footer: Footer

    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder transcript: () -> Transcript,
        @ViewBuilder footer: () -> Footer
    ) {
        self.header = header()
        self.transcript = transcript()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            header.layoutPriority(1)
            transcript
                .frame(minHeight: 0, maxHeight: .infinity)
                .clipped()
            footer.layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Follows the newest turn without losing it when its viewport shrinks.
    /// Reading older turns keeps the current position during layout changes.
    func followsNewest(_ utterances: [Utterance], proxy: ScrollViewProxy) -> some View {
        modifier(TranscriptFollowingModifier(utterances: utterances, proxy: proxy))
    }
}

private struct TranscriptFollowingModifier: ViewModifier {
    let utterances: [Utterance]
    let proxy: ScrollViewProxy
    @State private var followsBottom = true
    @State private var userIsScrolling = false
    @State private var viewportSize = CGSize.zero
    @State private var contentSize = CGSize.zero
    @State private var pendingTargetID: UUID?
    @State private var reflowRevision = 0
    @State private var alignmentGeneration = 0
    @State private var alignmentTask: Task<Void, Never>?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var last: Utterance? { utterances.last }

    private struct TextRevision: Equatable {
        let id: UUID?
        let source: String
        let translation: String
    }

    private var textRevision: TextRevision {
        TextRevision(id: last?.id, source: last?.trimmedSource ?? "", translation: last?.translation ?? "")
    }

    private struct Reflow: Equatable {
        let viewport: CGSize
        let content: CGSize
        let typeSize: DynamicTypeSize
        let newestID: UUID?
        let source: String
        let translation: String
    }

    private var reflow: Reflow {
        Reflow(viewport: viewportSize, content: contentSize, typeSize: dynamicTypeSize, newestID: last?.id,
               source: last?.trimmedSource ?? "", translation: last?.translation ?? "")
    }

    nonisolated private struct NativeLayout: Equatable {
        let viewport: CGSize
        let content: CGSize
    }

    func body(content: Content) -> some View {
        content
            .onAppear { scrollToNewest() }
            .onChange(of: last?.id) { _, _ in
                guard !userIsScrolling else { return }
                followsBottom = true
                scrollToNewest()
            }
            .onChange(of: textRevision) { previous, current in
                guard previous.id == current.id, followsBottom, !userIsScrolling else { return }
                // Streaming text can change faster than a layout debounce.
                // Follow it immediately; the settled reflow corrects wrapping.
                scrollToNewest()
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                isNearBottom(geometry)
            } action: { _, nearBottom in
                if userIsScrolling { followsBottom = nearBottom }
            }
            // View geometry can reach its target before the scroll container
            // finishes resizing. Follow the container's actual layout instead.
            .onScrollGeometryChange(for: NativeLayout.self) {
                NativeLayout(viewport: $0.containerSize, content: $0.contentSize)
            } action: { _, metrics in
                viewportSize = metrics.viewport
                contentSize = metrics.content
            }
            .onScrollPhaseChange { oldPhase, newPhase, context in
                let wasUserScrolling = isUserPhase(oldPhase)
                userIsScrolling = isUserPhase(newPhase)
                if wasUserScrolling || userIsScrolling {
                    followsBottom = isNearBottom(context.geometry)
                }
                if userIsScrolling {
                    cancelAlignment()
                } else if wasUserScrolling && followsBottom {
                    requestAlignment(for: reflow)
                }
            }
            .onChange(of: reflow, initial: true) { _, change in requestAlignment(for: change) }
            .onDisappear { cancelAlignment() }
    }

    private func scrollToNewest() {
        if let target = last?.id { align(to: target) }
    }

    private func align(to target: UUID) {
        // A second request can interrupt an animated scroll before it reaches
        // the newest turn. Keep alignment immediate while rows animate normally.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(target, anchor: .bottom) }
    }

    private func requestAlignment(for change: Reflow) {
        pendingTargetID = change.newestID
        reflowRevision &+= 1
        guard viewportSize.width > 0, viewportSize.height > 0,
              followsBottom, !userIsScrolling, alignmentTask == nil else { return }
        alignmentGeneration &+= 1
        let token = alignmentGeneration
        alignmentTask = Task {
            defer {
                if alignmentGeneration == token { alignmentTask = nil }
            }
            while !Task.isCancelled {
                let revision = reflowRevision
                // Coalesce layout work without postponing it indefinitely:
                // live text may keep changing faster than this interval.
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return }
                guard alignmentGeneration == token, followsBottom, !userIsScrolling else { return }
                if let pendingTargetID { align(to: pendingTargetID) }
                if revision == reflowRevision { return }
            }
        }
    }

    private func cancelAlignment() {
        alignmentGeneration &+= 1
        alignmentTask?.cancel()
        alignmentTask = nil
    }

    nonisolated private func isNearBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentSize.height - geometry.visibleRect.maxY <= 24
    }

    nonisolated private func isUserPhase(_ phase: ScrollPhase) -> Bool {
        phase == .tracking || phase == .interacting || phase == .decelerating
    }
}
