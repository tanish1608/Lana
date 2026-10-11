import Foundation
import Testing
import FWMCore
@testable import FinanceAI

private let relayURL = ProcessInfo.processInfo.environment["RELAY_TEST_URL"].flatMap(URL.init(string:))
private let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/seed-v1.json")

/// A text arriving at the relay as if Dial delivered it. Needs the relay in dev mode, see relay/README.md.
private func inject(_ base: URL, _ text: String) async throws {
    var request = URLRequest(url: base.appendingPathComponent("dev/inbound"))
    request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: ["from": "+15550001111", "text": text])
    _ = try await URLSession.shared.data(for: request)
}

/// RELAY_TEST_URL=http://localhost:8790 against `RELAY_DEV=1 PAIRING_CODE=424242 PAIRED_PHONES=+15550001111=user_ashwin`.
@Test(.enabled(if: relayURL != nil)) func relayJobRunsThroughCoreAgentOnThePhone() async throws {
    let base = try #require(relayURL)
    let ds = try Dataset.load(from: fixtureURL)
    let pairing = try await RelayClient.pair(baseURL: base, code: "424242")
    let worker = RelayWorker(client: RelayClient(baseURL: base, deviceToken: pairing.deviceToken),
                             tools: CoreDatasetTools(dataset: ds), contextFor: RelayWorker.datasetContext(ds, period: "2026-09"))

    try await inject(base, "Where is my money going?")
    let money = try #require(try await worker.runOnce(wait: 5))
    #expect(money.replyText.contains("$4,800.00"))
    #expect(money.replyText.contains("$11,550.00"))
    #expect(money.provenance?.resultId == "mv:seed-v1:2026-09:all")

    // No budget adapter is connected here, so the sender gets the tool's message instead of a made-up plan.
    try await inject(base, "Make me a budget that saves $150 a month")
    let budget = try #require(try await worker.runOnce(wait: 5))
    #expect(budget.provenance == nil)
    #expect(!budget.replyText.isEmpty)

    #expect(try await worker.runOnce(wait: 1) == nil)
}
