import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// SimpleFIN Bridge adapter (https://www.simplefin.org/protocol.html). A user connects their bank at SimpleFIN Bridge,
// then gives the app a one-time setup token; claiming it returns an access URL with Basic credentials. The phone reads
// accounts directly from SimpleFIN: no relay, no aggregator SDK. Like BankCSVProvider, records normalize into the
// shared Dataset shape, so the engines don't know where they came from.

public enum SimpleFIN {
    /// SimpleFIN's public demo access URL: synthetic accounts served by the real API, for trying the flow.
    public static let demoAccessURL = URL(string: "https://demo:demo@beta-bridge.simplefin.org/simplefin")!

    public struct AccountSet: Decodable, Sendable {
        public var errlist: [Problem]?
        public var connections: [Connection]?
        public var accounts: [RemoteAccount]
    }
    public struct Problem: Decodable, Sendable { public var code: String?; public var msg: String? }
    public struct Connection: Decodable, Sendable {
        public var connId: String
        public var name: String?
        public var orgName: String?
        enum CodingKeys: String, CodingKey { case connId = "conn_id", name, orgName = "org_name" }
    }
    public struct RemoteAccount: Decodable, Sendable {
        public var id: String
        public var name: String
        public var connId: String?
        public var currency: String
        public var balance: String
        public var balanceDate: Int
        public var transactions: [RemoteTransaction]?
        enum CodingKeys: String, CodingKey { case id, name, connId = "conn_id", currency, balance, balanceDate = "balance-date", transactions }
    }
    public struct RemoteTransaction: Decodable, Sendable {
        public var id: String
        public var posted: Int
        public var amount: String
        public var description: String
        public var payee: String?
        public var transactedAt: Int?
        public var pending: Bool?
        public var mcc: String?
        enum CodingKeys: String, CodingKey { case id, posted, amount, description, payee, transactedAt = "transacted_at", pending, mcc }
    }

    /// A setup token is base64 of a claim URL. Only HTTPS claim URLs are accepted.
    public static func claimURL(setupToken: String) throws -> URL {
        let cleaned = setupToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: cleaned) ?? Data(base64Encoded: cleaned + String(repeating: "=", count: (4 - cleaned.count % 4) % 4)),
              let text = String(data: data, encoding: .utf8), let url = URL(string: text), url.scheme == "https", url.host != nil else {
            throw ToolError(.invalidArguments, "That doesn't look like a SimpleFIN setup token. Copy it again from SimpleFIN Bridge.")
        }
        return url
    }

    /// Exchanges a one-time setup token for an access URL. A token can be claimed once; store the result securely.
    public static func claim(setupToken: String, session: URLSession = .shared) async throws -> URL {
        var request = URLRequest(url: try claimURL(setupToken: setupToken))
        request.httpMethod = "POST"
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: text), url.scheme == "https", url.user != nil else {
            throw ToolError(status == 403 ? .authRequired : .providerUnavailable,
                            status == 403 ? "This setup token was already used or doesn't exist. Create a new one in SimpleFIN Bridge." : "SimpleFIN didn't return an access URL (HTTP \(status)).",
                            retryable: status != 403)
        }
        return url
    }

    /// Reads accounts and transactions posted since `since` (SimpleFIN returns about a day by default).
    public static func fetch(accessURL: URL, since: Date?, session: URLSession = .shared) async throws -> AccountSet {
        guard var parts = URLComponents(url: accessURL, resolvingAgainstBaseURL: false), parts.scheme == "https",
              let user = parts.user, let password = parts.password else {
            throw ToolError(.invalidArguments, "The SimpleFIN access URL is missing its credentials.")
        }
        parts.user = nil; parts.password = nil
        parts.path = parts.path.hasSuffix("/") ? parts.path + "accounts" : parts.path + "/accounts"
        parts.queryItems = [URLQueryItem(name: "version", value: "2"), URLQueryItem(name: "pending", value: "1")]
            + (since.map { [URLQueryItem(name: "start-date", value: String(Int($0.timeIntervalSince1970)))] } ?? [])
        guard let url = parts.url else { throw ToolError(.invalidArguments, "The SimpleFIN access URL is invalid.") }
        var request = URLRequest(url: url)
        request.setValue("Basic " + Data("\(user.removingPercentEncoding ?? user):\(password.removingPercentEncoding ?? password)".utf8).base64EncodedString(),
                         forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ToolError(status == 403 || status == 401 ? .authRequired : .providerUnavailable,
                            status == 403 || status == 401 ? "SimpleFIN access was revoked. Reconnect the bank." : "SimpleFIN is unavailable (HTTP \(status)).",
                            retryable: status >= 500)
        }
        do { return try JSONDecoder().decode(AccountSet.self, from: data) }
        catch { throw ToolError(.providerUnavailable, "SimpleFIN returned data Lana couldn't read.") }
    }

    public struct Normalized: Sendable {
        public var accounts: [Account]
        public var transactions: [Transaction]
        public var warnings: [String]
    }

    /// Maps SimpleFIN records into normalized accounts and transactions in the user's timezone. Non-USD accounts and
    /// amounts with more than two decimals are skipped with a warning rather than rounded.
    public static func normalize(_ set: AccountSet, user: UserPrefs, asOf: String) -> Normalized {
        let tz = TimeZone(identifier: user.timezone) ?? TimeZone(identifier: "America/Los_Angeles")!
        let names = Dictionary((set.connections ?? []).map { ($0.connId, $0.name ?? $0.orgName ?? "Bank") }, uniquingKeysWith: { a, _ in a })
        var out = Normalized(accounts: [], transactions: [], warnings: (set.errlist ?? []).compactMap(\.msg))
        for a in set.accounts {
            guard a.currency == "USD" else { out.warnings.append("\(a.name): \(a.currency) accounts aren't supported yet."); continue }
            guard let balance = cents(a.balance) else { out.warnings.append("\(a.name): unreadable balance."); continue }
            let kind = Self.kind(a.name), side: Account.Side = ["credit_card", "loan", "student_loan", "mortgage"].contains(kind) ? .liability : .asset
            let key = digest("\(a.connId ?? "")|\(a.id)")
            let accountID = "sfin_\(key)"
            // SimpleFIN reports what's owed on a card or loan as a negative balance; Dataset liabilities are positive.
            out.accounts.append(Account(accountId: accountID, institution: a.connId.flatMap { names[$0] } ?? "Bank", kind: kind, assetOrLiability: side,
                                        openingBalanceCents: nil, balanceCents: side == .liability ? -balance : balance,
                                        asOf: iso(a.balanceDate, tz) ?? asOf, sourceId: "sfin:\(key)"))
            for t in a.transactions ?? [] {
                guard let amount = cents(t.amount) else { out.warnings.append("\(a.name): skipped \(t.description), unreadable amount."); continue }
                let when = t.posted > 0 ? t.posted : (t.transactedAt ?? a.balanceDate)
                guard let posted = iso(when, tz) else { continue }
                let id = digest("\(key)|\(t.id)")
                out.transactions.append(Transaction(transactionId: "sfin_\(id)", accountId: accountID, postedAt: posted, signedAmountCents: amount,
                    merchant: (t.payee?.isEmpty == false ? t.payee! : t.description), category: category(mcc: t.mcc),
                    pending: t.pending ?? (t.posted == 0), transferPairId: nil, refundOf: nil, sourceId: "sfin:\(key):\(t.id)"))
            }
        }
        return out
    }

    /// Exact decimal string ("-55.50", "113985.51") to cents.
    static func cents(_ raw: String) -> Int? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        let negative = s.hasPrefix("-")
        if negative || s.hasPrefix("+") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard !s.isEmpty, parts.count <= 2, let whole = Int(parts[0].isEmpty ? "0" : parts[0]), whole < 10_000_000_000 else { return nil }
        var frac = 0
        if parts.count == 2 {
            guard parts[1].count <= 2, parts[1].allSatisfy(\.isNumber) else { return nil }
            frac = Int(parts[1].padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0
        }
        return (negative ? -1 : 1) * (whole * 100 + frac)
    }

    static func kind(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("credit") || n.contains("card") { return "credit_card" }
        if n.contains("student") { return "student_loan" }
        if n.contains("mortgage") { return "mortgage" }
        if n.contains("loan") { return "loan" }
        if n.contains("saving") || n.contains("money market") { return "savings" }
        if n.contains("brokerage") || n.contains("invest") || n.contains("ira") || n.contains("401") { return "brokerage" }
        return "checking"
    }

    /// The common merchant category codes, mapped to the app's spending categories.
    static func category(mcc: String?) -> String? {
        switch mcc {
        case "5411", "5422", "5441", "5451", "5462", "5499": return "Groceries"
        case "5812", "5813", "5814": return "Dining"
        case "4111", "4121", "4131", "4789", "5541", "5542", "7523": return "Transport"
        case "4812", "4814", "4899", "4900": return "Bills and subscriptions"
        default: return nil
        }
    }

    private static func digest(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined() }

    private static func iso(_ epoch: Int, _ tz: TimeZone) -> String? {
        guard epoch > 0 else { return nil }
        let f = ISO8601DateFormatter()
        f.timeZone = tz
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }
}
