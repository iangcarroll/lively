import Foundation

/// State of one Soniox stream across WebSockets. Request numbers include every
/// audio and control frame after the start request except application pings.
final class SonioxReconnect {
    typealias Message = URLSessionWebSocketTask.Message

    private var request: URLRequest
    private(set) var token: String?
    var resumeRequest: URLRequest? { token == nil ? nil : request }
    var deadline: ContinuousClock.Instant?
    var lastSequence = 0
    private(set) var requestCount = 0
    private var pending: [Message] = []
    private var pingID: Int?
    private let capacity: Int

    init(request: URLRequest, capacity: Int) {
        self.request = request
        self.capacity = capacity
    }

    func acceptOffer(_ json: [String: Any]) -> Bool {
        guard token == nil, let value = json["reconnect_token"] as? String, !value.isEmpty,
              let raw = json["reconnect_url"] as? String, let url = URL(string: raw),
              let origin = request.url, url.scheme == origin.scheme, url.host == origin.host,
              url.port == origin.port, url.user == nil, url.password == nil else { return false }
        request.url = url
        token = value
        return true
    }

    func record(_ message: Message) {
        requestCount += 1
        pending.append(message)
        if pending.count > capacity { pending.removeFirst() }
    }

    func ping() -> Message? {
        guard pingID == nil else { return nil }
        pingID = requestCount
        return .json(["type": "ping", "id": requestCount])
    }

    func pong(_ id: Int?) {
        guard let id, id == pingID else { return }
        pingID = nil
        discard(through: id)
    }

    private func discard(through id: Int) {
        let retainedAfter = requestCount - pending.count
        if id > retainedAfter { pending.removeFirst(id - retainedAfter) }
    }

    var handshake: Message {
        .json(["type": "reconnect", "reconnect_token": token!, "last_seq": lastSequence])
    }

    /// A server watermark outside retained history requires a fresh stream.
    func acceptResume(_ json: [String: Any], sentBeforeDrop: Int) -> [Message]? {
        guard let value = json["reconnect_token"] as? String, !value.isEmpty,
              let last = json["last_request"] as? Int,
              last >= requestCount - pending.count, last <= sentBeforeDrop else { return nil }
        discard(through: last)
        token = value
        pingID = nil
        deadline = nil
        return pending
    }

}
