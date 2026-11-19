#if os(iOS)
import Foundation
import StoreKit
import Testing
@testable import Lively

@MainActor
struct AppleAdsAttributionTests {
    @Test func retryUsesSameTokenAndPurchaseCarriesInstallID() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let broker = URL(string: "https://broker.example")!
        let client = AppleAdsAttribution(directory: folder)
        let pendingOptions = client.purchaseOptions
        var requests: [URLRequest] = []
        var delays: [Duration] = []
        let opaque = UUID().uuidString
        await client.collect(broker: broker, token: { opaque }, send: { request in
            requests.append(request)
            let waiting = requests.count == 1
            return (Data(#"{"attributed":true}"#.utf8), HTTPURLResponse(url: broker, statusCode: waiting ? 503 : 200,
                    httpVersion: nil, headerFields: waiting ? ["Retry-After": "5"] : [:])!)
        }, sleep: { delays.append($0) })
        #expect(requests.count == 2 && delays == [.seconds(5)])
        let request = try #require(requests.last)
        #expect(request.url?.path == "/v1/apple-ads/attribution")
        #expect(request.httpBody == Data(opaque.utf8))
        let header = try #require(request.value(forHTTPHeaderField: "Lively-Attribution-ID"))
        let id = try #require(UUID(uuidString: header))
        #expect(pendingOptions == [.appAccountToken(id)])
        let relaunched = AppleAdsAttribution(directory: folder)
        #expect(relaunched.purchaseOptions == pendingOptions)
        await relaunched.collect(broker: broker, token: { Issue.record("Repeated a completed lookup"); return opaque },
                                 send: { _ in throw URLError(.badServerResponse) })
    }

    @Test func failedLookupCanRecoverAndOrganicCheckoutOmitsTheReference() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let broker = URL(string: "https://broker.example")!
        let client = AppleAdsAttribution(directory: folder)
        await client.collect(broker: broker, token: { "first" }, send: { _ in throw URLError(.notConnectedToInternet) })
        #expect(!client.purchaseOptions.isEmpty)
        let relaunched = AppleAdsAttribution(directory: folder)
        await relaunched.collect(broker: broker, token: { "fresh" }, send: { _ in
            (Data(#"{"attributed":false}"#.utf8), HTTPURLResponse(url: broker, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        #expect(AppleAdsAttribution(directory: folder).purchaseOptions.isEmpty)
    }
}
#endif
