import Foundation
import CryptoKit

// Phone side of the relay contract in relay/README.md. The app owns where the device token and approval
// secret live (Keychain) and when to poll (foreground only). This file only speaks the wire format.

public struct RelayPairing: Codable, Sendable, Equatable {
    public var deviceToken: String
    public var approvalSecret: String
    public var pairedUserId: String
}

public struct RelayJob: Codable, Sendable, Equatable {
    public var jobId: String
    public var envelope: MessageEnvelope
}

public struct SwapMemory: Codable, Sendable, Equatable {
    public var blockedGroups: [String]
    public var evidenceIds: [String]
    public var asOf: String
    public var dataMode: DataMode
    public var query: String
}

public struct TimeReceipt: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case manual, lana }
    public struct Row: Codable, Sendable, Equatable {
        public var workflow: String
        public var manualSeconds: Int?
        public var lanaSeconds: Int?
        public var savedSeconds: Int?
        public var manualRuns: Int
        public var lanaRuns: Int
    }
    public var rows: [Row]
    public var totalSavedSeconds: Int
    /// "live" (Keewano) or "local" (relay rows while Keewano indexes).
    public var dataMode: String
    public var asOf: String
}

public struct ReminderRecord: Codable, Sendable, Equatable {
    public enum Status: String, Codable, Sendable { case scheduled, dispatching, sent, deliveryUnknown = "delivery_unknown", failed, paid, disputed, cancelled }
    public var reminderId: String
    public var actionId: String
    public var contactId: String
    public var body: String
    /// Unix milliseconds on the demo clock.
    public var dueAt: Int
    public var status: Status
}

/// ACT-02 approval: binds the exact payload, a one-time nonce and an expiry, signed with the device's approval secret.
/// Sign only after the user approves (and passes MFA) on the confirm screen.
public struct Approval: Codable, Sendable, Equatable {
    public var actionId: String
    public var payloadHash: String
    public var nonce: String
    public var expiresAt: String
    public var mac: String

    public static func sign(actionId: String, payload: [String: String], secret: String,
                            nonce: String = UUID().uuidString, expiresAt: Date = Date().addingTimeInterval(300)) -> Approval {
        let expires = iso8601(expiresAt)
        let hash = hex(SHA256.hash(data: Data(canonicalJSON(payload).utf8)))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(actionId).\(hash).\(nonce).\(expires)".utf8),
                                                  using: SymmetricKey(data: Data(secret.utf8)))
        return Approval(actionId: actionId, payloadHash: hash, nonce: nonce, expiresAt: expires, mac: hex(mac))
    }

    /// Same bytes as relay/src/canonical.ts: keys sorted, no whitespace, strings escaped like JSON.stringify.
    public static func canonicalJSON(_ payload: [String: String]) -> String {
        "{" + payload.keys.sorted().map { "\(quote($0)):\(quote(payload[$0]!))" }.joined(separator: ",") + "}"
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out + "\""
    }

    static func iso8601(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    static func hex<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct RelayClient: Sendable {
    public var baseURL: URL
    public var deviceToken: String
    var session: URLSession

    public init(baseURL: URL, deviceToken: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.deviceToken = deviceToken
        self.session = session
    }

    /// One-time pairing with the code the relay prints on boot. Store both secrets in the Keychain.
    public static func pair(baseURL: URL, code: String, pairedUserId: String? = nil, session: URLSession = .shared) async throws -> RelayPairing {
        var body = ["code": code]
        if let pairedUserId { body["paired_user_id"] = pairedUserId }
        let client = RelayClient(baseURL: baseURL, deviceToken: "", session: session)
        return try await client.send("POST", "/v1/pair", json: body, auth: false)
    }

    /// Long poll for the next job. Returns nil when nothing arrived within `wait` seconds (max 30).
    /// Polling marks this device as open, so the relay will not send the "Open FWM" nudge.
    public func nextJob(wait: Int = 25) async throws -> RelayJob? {
        var req = request("GET", "/v1/jobs/next?wait=\(min(max(wait, 0), 30))")
        req.timeoutInterval = TimeInterval(wait + 10)
        let (data, res) = try await session.data(for: req)
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        if status == 204 { return nil }
        try check(status, data)
        return try FWMJSON.decoder.decode(RelayJob.self, from: data)
    }

    /// Bytes for an inbound receipt photo or voice note, proxied by the relay.
    public func attachment(_ ref: AttachmentRef) async throws -> (data: Data, mimeType: String?) {
        let (data, res) = try await session.data(for: request("GET", "/v1/attachments/\(ref.attachmentId)"))
        let http = res as? HTTPURLResponse
        try check(http?.statusCode ?? 0, data)
        return (data, http?.value(forHTTPHeaderField: "Content-Type") ?? ref.mimeType)
    }

    /// Hands the answer back. The relay sends `replyText` (and the card image, if given) to the sender once,
    /// even if this is called again for the same job.
    public func postResult(_ result: AgentResult, card: Data? = nil, cardContentType: String = "image/png") async throws {
        struct Card: Encodable { let base64: String; let contentType: String }
        struct Body: Encodable {
            let jobId: String, replyText: String, cardId: String?, proposedActionId: String?, provenance: Provenance?, card: Card?
        }
        let body = Body(jobId: result.jobId, replyText: result.replyText, cardId: result.cardId, proposedActionId: result.proposedActionId,
                        provenance: result.provenance, card: card.map { Card(base64: $0.base64EncodedString(), contentType: cardContentType) })
        let _: AnyJSON = try await send("POST", "/v1/jobs/\(result.jobId)/result", json: body)
    }

    /// SPLIT-08: schedule one reminder for an approved split request. The approval must be signed over exactly these fields.
    public func scheduleReminder(actionId: String, splitId: String?, contactId: String, to: String, body: String,
                                 dueAt: Date, approvalSecret: String) async throws -> ReminderRecord {
        let due = Approval.iso8601(dueAt)
        let payload = ["action_id": actionId, "contact_id": contactId, "to": to, "body": body, "due_at": due]
        struct Req: Encodable { let actionId, contactId, to, body, dueAt: String; let splitId: String?; let approval: Approval }
        let approval = Approval.sign(actionId: actionId, payload: payload, secret: approvalSecret)
        return try await send("POST", "/v1/reminders", json: Req(actionId: actionId, contactId: contactId, to: to, body: body,
                                                                 dueAt: due, splitId: splitId, approval: approval))
    }

    /// Marking a request paid or disputed cancels its reminder if it has not fired.
    public func setReminderStatus(_ reminderId: String, _ status: ReminderRecord.Status) async throws -> ReminderRecord {
        try await send("POST", "/v1/reminders/\(reminderId)/status", json: ["status": status.rawValue])
    }

    /// Demo only: move the relay's reminder clock forward.
    public func advanceClock(seconds: Int) async throws {
        let _: AnyJSON = try await send("POST", "/v1/clock/advance", json: ["seconds": seconds])
    }

    /// BUD-04: which swap groups this user has rejected before (Keewano). `dataMode` is `cached` when Keewano was unreachable.
    public func swapMemory(userId: String, groups: [String]) async throws -> SwapMemory {
        var c = URLComponents()
        c.queryItems = [URLQueryItem(name: "user_id", value: userId), URLQueryItem(name: "groups", value: groups.joined(separator: ","))]
        return try await send("GET", "/v1/swap-memory?\(c.percentEncodedQuery ?? "")")
    }

    /// Time receipt: log one timed run of a chore. `workflow` is month_review, budget_swaps or bill_split.
    public func logTiming(workflow: String, mode: TimeReceipt.Mode, seconds: Int, runId: String? = nil) async throws {
        struct Body: Encodable { let workflow: String; let mode: TimeReceipt.Mode; let seconds: Int; let runId: String? }
        let _: AnyJSON = try await send("POST", "/v1/timings", json: Body(workflow: workflow, mode: mode, seconds: seconds, runId: runId))
    }

    /// Average manual vs Lana seconds per chore over measured runs. `dataMode` is live when it came from Keewano.
    public func timeReceipt() async throws -> TimeReceipt {
        try await send("GET", "/v1/time-receipt")
    }

    // MARK: wire

    func request(_ method: String, _ path: String, auth: Bool = true) -> URLRequest {
        var req = URLRequest(url: URL(string: path, relativeTo: baseURL)!)
        req.httpMethod = method
        req.setValue("1", forHTTPHeaderField: "ngrok-skip-browser-warning") // demo relay runs behind an ngrok tunnel
        if auth { req.setValue("Bearer \(deviceToken)", forHTTPHeaderField: "Authorization") }
        return req
    }

    func send<T: Decodable>(_ method: String, _ path: String, json: (any Encodable)? = nil, auth: Bool = true) async throws -> T {
        var req = request(method, path, auth: auth)
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try FWMJSON.encoder.encode(json)
        }
        let (data, res) = try await session.data(for: req)
        try check((res as? HTTPURLResponse)?.statusCode ?? 0, data)
        return try FWMJSON.decoder.decode(T.self, from: data)
    }

    /// Relay errors arrive as {"error": {code, retryable, user_message}} and surface as ToolError.
    func check(_ status: Int, _ data: Data) throws {
        guard !(200..<300).contains(status) else { return }
        struct Wrapped: Decodable { let error: ToolError }
        if let e = try? FWMJSON.decoder.decode(Wrapped.self, from: data) { throw e.error }
        throw ToolError(.providerUnavailable, "The relay is unavailable (HTTP \(status)).", retryable: true)
    }
}
