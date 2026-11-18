import Foundation
import Observation

/// Owns lookup work without involving microphone, conversation, or speech state.
@Observable
@MainActor
final class AddressLookupStore {
    enum Phase: Equatable { case idle, searching, choosing, localizing, resolved }

    var query = "" {
        didSet {
            guard query != oldValue else { return }
            reset()
        }
    }
    var language: AddressLanguage {
        didSet {
            guard language != oldValue else { return }
            if let selectedPlace { select(selectedPlace) }
            else {
                cancelWork()
                address = nil
                errorMessage = nil
                phase = matches.isEmpty ? .idle : .choosing
            }
        }
    }

    private(set) var phase: Phase = .idle
    private(set) var matches: [AddressPlace] = []
    private(set) var selectedPlace: AddressPlace?
    private(set) var address: String?
    private(set) var errorMessage: String?
    @ObservationIgnored private let service: any AddressLookupProviding
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var operation = UUID()

    init(service: any AddressLookupProviding, language: AddressLanguage) {
        self.service = service
        self.language = language
    }

    var isBusy: Bool { phase == .searching || phase == .localizing }
    var canSearch: Bool { !normalizedQuery.isEmpty && !isBusy }
    var copyValue: String? { phase == .resolved ? address : nil }

    private var normalizedQuery: String {
        query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    func find() {
        let input = normalizedQuery
        reset()
        guard !input.isEmpty else { return }
        guard input.count <= 1_000 else {
            errorMessage = "Use a shorter address or place name."
            return
        }
        guard !input.lowercased().hasPrefix("https://"), !input.lowercased().hasPrefix("http://") else {
            errorMessage = "Paste an address or place name instead of a map link."
            return
        }
        phase = .searching
        let token = operation
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let places = try await service.findPlaces(matching: input)
                guard isCurrent(token) else { return }
                matches = Array(places.filter(\.hasValidCoordinate).prefix(8))
                phase = matches.isEmpty ? .idle : .choosing
                if matches.isEmpty { errorMessage = "No places found. Add a city or country and try again." }
            } catch {
                guard isCurrent(token) else { return }
                phase = .idle
                if !(error is CancellationError) { errorMessage = message(for: error) }
            }
            if operation == token { work = nil }
        }
    }

    func select(_ place: AddressPlace) {
        guard matches.contains(place) else { return }
        cancelWork()
        selectedPlace = place
        address = nil
        errorMessage = nil
        phase = .localizing
        let token = operation
        let requestedLanguage = language
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await service.address(for: place, language: requestedLanguage)
                guard isCurrent(token) else { return }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw AddressLookupError.missingAddress }
                address = trimmed
                phase = .resolved
            } catch {
                guard isCurrent(token) else { return }
                phase = .choosing
                if !(error is CancellationError) { errorMessage = message(for: error) }
            }
            if operation == token { work = nil }
        }
    }

    func retry() {
        if let selectedPlace { select(selectedPlace) }
        else { find() }
    }

    func close() { reset() }

    private func reset() {
        cancelWork()
        matches = []
        selectedPlace = nil
        address = nil
        errorMessage = nil
        phase = .idle
    }

    private func cancelWork() {
        operation = UUID()
        work?.cancel()
        work = nil
        service.cancel()
    }

    private func isCurrent(_ token: UUID) -> Bool {
        operation == token && !Task.isCancelled
    }

    private func message(for error: Error) -> String {
        (error as? AddressLookupError)?.errorDescription ?? "Couldn’t look up this place. Try again."
    }
}
