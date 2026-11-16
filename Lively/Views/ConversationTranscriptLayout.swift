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
    @State private var pendingNewestID: UUID?
    @State private var reflowRevision = 0
    @State private var alignmentGeneration = 0
    @State private var alignmentTask: Task<Void, Never>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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

    func body(content: Content) -> some View {
        content
            .onAppear { scrollToNewest() }
            .onChange(of: last?.id) { _, _ in
                guard !userIsScrolling else { return }
                followsBottom = true
                withAnimation(reduceMotion ? nil : .snappy) { scrollToNewest() }
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
            .onScrollGeometryChange(for: CGSize.self) { $0.contentSize } action: { _, size in
                contentSize = size
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
            .onGeometryChange(for: CGSize.self) { $0.size } action: { viewportSize = $0 }
            .onChange(of: reflow, initial: true) { _, change in requestAlignment(for: change) }
            .onDisappear { cancelAlignment() }
    }

    private func scrollToNewest() {
        if let last { proxy.scrollTo(last.id, anchor: .bottom) }
    }

    private func requestAlignment(for change: Reflow) {
        pendingNewestID = change.newestID
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
                if let pendingNewestID { proxy.scrollTo(pendingNewestID, anchor: .bottom) }
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
