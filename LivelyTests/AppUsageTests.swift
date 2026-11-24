import Foundation
import Testing
@testable import Lively

@MainActor
struct AppUsageTests {
    private struct Batch: Decodable {
        let platform: String
        let days: [AppUsage.Day]
    }

    @Test func offlineSessionCrossesMidnightAndSurvivesRelaunch() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let broker = URL(string: "https://report.example")!
        let day = Int(Date.now.timeIntervalSince1970 / 86_400)
        var now = Date(timeIntervalSince1970: Double((day + 1) * 86_400 - 15))
        var elapsed = 100.0
        var failed: [URLRequest] = []
        let client = AppUsage(directory: folder, broker: broker, now: { now }, uptime: { elapsed }) { request in
            failed.append(request)
            throw URLError(.notConnectedToInternet)
        }
        client.foreground(false)
        client.foreground(true)
        client.foreground(true)
        await client.sync()
        now.addTimeInterval(30)
        elapsed += 30
        client.tick()
        await client.sync()
        let mid = try JSONDecoder().decode(Batch.self, from: #require(failed.last?.httpBody))
        #expect(mid.days.last == AppUsage.Day(day: day + 1))
        client.foreground(false)
        client.foreground(false)
        await client.sync()

        var uploaded: [URLRequest] = []
        let next = AppUsage(directory: folder, broker: broker, now: { now }, uptime: { elapsed }) {
            uploaded.append($0)
            return true
        }
        await next.sync()
        await next.sync()
        #expect(uploaded.count == 1)
        let request = try #require(uploaded.first)
        #expect(request.url?.path == "/v1/app-usage")
        let id = try #require(request.value(forHTTPHeaderField: "Lively-Usage-ID"))
        #expect(UUID(uuidString: id) != nil && failed.first?.value(forHTTPHeaderField: "Lively-Usage-ID") == id)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let actual = try JSONDecoder().decode(Batch.self, from: #require(request.httpBody))
        #expect(actual.days == [AppUsage.Day(day: day, opens: 1), AppUsage.Day(day: day + 1, closes: 1, seconds: 30)])
    }

    @Test func closeDuringUploadIsSentBeforeAcknowledgingTheDay() async throws {
        let folder = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var client: AppUsage!
        var batches: [Batch] = []
        client = AppUsage(directory: folder, broker: URL(string: "https://report.example")!) { request in
            batches.append(try JSONDecoder().decode(Batch.self, from: #require(request.httpBody)))
            if batches.count == 1 { client.foreground(false) }
            return true
        }
        client.foreground(true)
        await client.sync()
        await client.sync()
        #expect(batches.map { $0.days[0].closes } == [0, 1])
        #expect(batches.allSatisfy { $0.days[0].opens == 1 })
    }
}
