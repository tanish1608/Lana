import XCTest
@testable import FWMCore

final class RelayClientTests: XCTestCase {
    /// Vector produced by relay/src/canonical.ts + node:crypto. If this drifts, the relay rejects every approval.
    func testApprovalMatchesRelayBytes() {
        let payload = ["action_id": "act_test1", "contact_id": "c_tanish", "to": "+12014486556",
                       "body": "Dinner \"Oct 11\": $36.40\nthanks / 🍝 é\\", "due_at": "2026-10-13T20:00:00.000Z"]
        XCTAssertEqual(Approval.canonicalJSON(payload),
                       #"{"action_id":"act_test1","body":"Dinner \"Oct 11\": $36.40\nthanks / 🍝 é\\","contact_id":"c_tanish","due_at":"2026-10-13T20:00:00.000Z","to":"+12014486556"}"#)
        let expires = ISO8601DateFormatter().date(from: "2026-10-11T21:00:00Z")!
        let a = Approval.sign(actionId: "act_test1", payload: payload, secret: "secret-abc", nonce: "nonce-1", expiresAt: expires)
        XCTAssertEqual(a.expiresAt, "2026-10-11T21:00:00.000Z")
        XCTAssertEqual(a.payloadHash, "10b504e054f1569d508e6080e4a347484256b7571dff8c5e8890b7fc9948a4f4")
        XCTAssertEqual(a.mac, "6d8c8a84f3dcaa990214c0bacc8c58786ae143fd4c4b3ef1e29908f0afbfaab4")
    }

    func testDecodesRelayJob() throws {
        let json = #"{"job_id":"job_1","envelope":{"event_id":"evt_1","conversation_id":"conv_a","paired_user_id":"user_ashwin","channel":"imessage","received_at":"2026-10-11T19:56:38.659Z","text":null,"attachments":[{"attachment_id":"att_1","kind":"image","mime_type":"image/jpeg","url":"http://localhost:8787/v1/attachments/att_1"}],"provider_message_id":"msg_9"}}"#
        let job = try FWMJSON.decoder.decode(RelayJob.self, from: Data(json.utf8))
        XCTAssertEqual(job.envelope.pairedUserId, "user_ashwin")
        XCTAssertEqual(job.envelope.attachments.first?.kind, .image)
        XCTAssertNil(job.envelope.text)
    }

    func testDecodesTimeReceipt() throws {
        let json = #"{"rows":[{"workflow":"bill_split","manual_seconds":600,"lana_seconds":40,"saved_seconds":560,"manual_runs":2,"lana_runs":1},{"workflow":"month_review","manual_seconds":null,"lana_seconds":null,"saved_seconds":null,"manual_runs":0,"lana_runs":0}],"total_saved_seconds":560,"data_mode":"local","as_of":"2026-10-11T20:30:00.000Z","query":null}"#
        let r = try FWMJSON.decoder.decode(TimeReceipt.self, from: Data(json.utf8))
        XCTAssertEqual(r.rows.first?.savedSeconds, 560)
        XCTAssertNil(r.rows.last?.manualSeconds)
        XCTAssertEqual(r.totalSavedSeconds, 560)
    }

    /// Full loop against a running relay. Start one with:
    /// cd relay && RELAY_DEV=1 PAIRING_CODE=424242 PAIRED_PHONES=+15550001111=user_ashwin PORT=8798 RELAY_DB=data/swift-test.db npm start
    /// then: RELAY_TEST_URL=http://localhost:8798 swift test --filter RelayClientTests
    func testLiveRelayLoop() async throws {
        guard let base = ProcessInfo.processInfo.environment["RELAY_TEST_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("RELAY_TEST_URL not set")
        }
        let pairing = try await RelayClient.pair(baseURL: base, code: "424242")
        let relay = RelayClient(baseURL: base, deviceToken: pairing.deviceToken)

        var inject = URLRequest(url: base.appendingPathComponent("dev/inbound"))
        inject.httpMethod = "POST"
        inject.httpBody = Data(#"{"from":"+15550001111","text":"how did September go?"}"#.utf8)
        _ = try await URLSession.shared.data(for: inject)

        let job = try await XCTUnwrapAsync(try await relay.nextJob(wait: 5))
        XCTAssertEqual(job.envelope.text, "how did September go?")
        let result = AgentResult(jobId: job.jobId, replyText: "September: $4,800 in, $3,150 spent, $1,650 kept.")
        try await relay.postResult(result)
        try await relay.postResult(result)

        let reminder = try await relay.scheduleReminder(actionId: "act_\(UUID().uuidString.prefix(8))", splitId: "split_dinner",
                                                        contactId: "c_tanish", to: "+15550001111", body: "Reminder: $36.40 for dinner.",
                                                        dueAt: Date().addingTimeInterval(48 * 3600), approvalSecret: pairing.approvalSecret)
        XCTAssertEqual(reminder.status, .scheduled)
        do {
            _ = try await relay.scheduleReminder(actionId: "act_forged", splitId: nil, contactId: "c_tanish", to: "+15550001111",
                                                 body: "x", dueAt: Date(), approvalSecret: "wrong-secret")
            XCTFail("forged approval accepted")
        } catch let e as ToolError {
            XCTAssertEqual(e.code, .authRequired)
        }
        let paid = try await relay.setReminderStatus(reminder.reminderId, .paid)
        XCTAssertEqual(paid.status, .paid)
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?) async throws -> T {
    let v = try await value()
    return try XCTUnwrap(v)
}
