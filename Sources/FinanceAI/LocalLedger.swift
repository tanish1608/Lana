import Foundation
import CryptoKit
import SQLite3
import FWMCore

/// What the chat agent may ask the on-device ledger. The model picks an operation and plain-text filters;
/// it never writes SQL. Every query is parameterized and scoped to the authenticated user and owned accounts.
public struct LedgerRequest: Sendable, Equatable {
    public enum Operation: String, Sendable, CaseIterable { case search, categories, merchants, accounts, activity }
    public var operation: Operation
    /// Merchant, category or activity words to match; nil for everything.
    public var text: String?
    /// Inclusive local dates, YYYY-MM-DD.
    public var from: String?
    public var to: String?
    public var limit: Int
    public init(operation: Operation, text: String? = nil, from: String? = nil, to: String? = nil, limit: Int = 15) {
        self.operation = operation; self.text = text; self.from = from; self.to = to; self.limit = limit
    }
}

public extension LedgerRequest {
    /// Dates the user actually wrote, read deterministically so a model that leaves `from`/`to` empty can't turn a
    /// dated question into an all-time total. Two ISO dates give a range; one ISO month or a month name (in the
    /// conversation's year) gives that whole month. Nil when the text names no date.
    static func dateWindow(in text: String, period: String) -> (from: String, to: String)? {
        let lower = text.lowercased()
        func matches(_ pattern: String) -> [String] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
            return re.matches(in: lower, range: NSRange(lower.startIndex..., in: lower)).compactMap { Range($0.range, in: lower).map { String(lower[$0]) } }
        }
        let days = matches(#"\b\d{4}-\d{2}-\d{2}\b"#).filter { (try? LocalLedger.validDate($0)) != nil }
        if days.count >= 2 { return (min(days[0], days[1]), max(days[0], days[1])) }
        if days.count == 1 { return (days[0], days[0]) }
        func month(_ year: Int, _ m: Int) -> (String, String)? {
            guard (1...12).contains(m), (1900...2999).contains(year) else { return nil }
            var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
            guard let start = cal.date(from: DateComponents(year: year, month: m, day: 1)), let range = cal.range(of: .day, in: .month, for: start) else { return nil }
            return (String(format: "%04d-%02d-01", year, m), String(format: "%04d-%02d-%02d", year, m, range.count))
        }
        if let iso = matches(#"\b\d{4}-\d{2}\b"#).first, let y = Int(iso.prefix(4)), let m = Int(iso.suffix(2)) { return month(y, m) }
        let names = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        // "may" is also a verb; only count it next to a year.
        let named = words.enumerated().compactMap { i, w -> (Int, Int?)? in
            guard let m = names.firstIndex(of: w) else { return nil }
            let year = words.indices.contains(i + 1) ? Int(words[i + 1]).flatMap { (1900...2999).contains($0) ? $0 : nil } : nil
            return w == "may" && year == nil ? nil : (m + 1, year)
        }
        guard named.count == 1, let (m, year) = named.first, let fallback = Int(period.prefix(4)) else { return nil }
        return month(year ?? fallback, m)
    }
}

public protocol LedgerQuerying: Sendable {
    func query(_ request: LedgerRequest, scope: CoreScope) async throws -> CoreToolOutput
}

/// Something the user did in the app, kept so the agent (and the Approvals list) can recall it after relaunch.
public struct LedgerEvent: Sendable, Equatable {
    public var kind: String
    public var summary: String
    public var occurredAt: Date
    public var details: [String: String]
    public init(kind: String, summary: String, occurredAt: Date = Date(), details: [String: String] = [:]) {
        self.kind = kind; self.summary = summary; self.occurredAt = occurredAt; self.details = details
    }
}

/// App-private SQLite database on the phone: the current dataset's accounts and transactions, mirrored so the agent
/// can search and total them, plus an append-only activity journal. Imported statement accounts persist here across
/// relaunches. Nothing in this file talks to a network. Amounts are integer cents; totals use the MoneyEngine's
/// definitions (pending, transfers and income excluded from spending; the last update of a source id wins).
public actor LocalLedger: LedgerQuerying {
    public static let engineVersion = "ledger-1.0"
    // Set once in init and only used on this actor; deinit is the one nonisolated reader.
    private nonisolated(unsafe) let db: OpaquePointer?
    private let url: URL

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("ledger.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw FinanceAIError.unavailable("Couldn't open the local ledger: \(message)")
        }
        db = handle
        try Self.exec(handle, """
            PRAGMA journal_mode = WAL;
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS accounts (
              user_id TEXT NOT NULL, account_id TEXT NOT NULL, institution TEXT NOT NULL, kind TEXT NOT NULL,
              side TEXT NOT NULL, opening_cents INTEGER, balance_cents INTEGER NOT NULL, as_of TEXT NOT NULL,
              source_id TEXT, origin TEXT NOT NULL, PRIMARY KEY (user_id, account_id));
            CREATE TABLE IF NOT EXISTS transactions (
              user_id TEXT NOT NULL, source_key TEXT NOT NULL, transaction_id TEXT NOT NULL, account_id TEXT NOT NULL,
              posted_at TEXT NOT NULL, posted_date TEXT NOT NULL, amount_cents INTEGER NOT NULL, merchant TEXT NOT NULL,
              category TEXT, pending INTEGER NOT NULL, transfer_pair_id TEXT, refund_of TEXT, source_id TEXT,
              PRIMARY KEY (user_id, source_key),
              FOREIGN KEY (user_id, account_id) REFERENCES accounts (user_id, account_id) ON DELETE CASCADE);
            CREATE INDEX IF NOT EXISTS transactions_by_date ON transactions (user_id, posted_date);
            CREATE TABLE IF NOT EXISTS events (
              seq INTEGER PRIMARY KEY AUTOINCREMENT, user_id TEXT NOT NULL, kind TEXT NOT NULL, summary TEXT NOT NULL,
              occurred_at REAL NOT NULL, details TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS events_by_user ON events (user_id, seq);
            CREATE TABLE IF NOT EXISTS category_overrides (
              user_id TEXT NOT NULL, transaction_id TEXT NOT NULL, category TEXT NOT NULL, PRIMARY KEY (user_id, transaction_id));
            """)
        #if os(iOS)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var excluded = directory; try? excluded.setResourceValues(values)
    }

    deinit { sqlite3_close(db) }

    // MARK: dataset mirror

    /// Replaces this user's mirrored accounts and transactions with `dataset`. Accounts whose source id starts with
    /// `csv:` are stored as imported, so `importedAccounts` can restore them on the next launch.
    public func sync(_ dataset: Dataset) throws {
        let user = dataset.user.userId
        let tz = TimeZone(identifier: dataset.user.timezone) ?? TimeZone(identifier: "America/Los_Angeles")!
        try transaction {
            try run("DELETE FROM transactions WHERE user_id = ?", [.text(user)])
            try run("DELETE FROM accounts WHERE user_id = ?", [.text(user)])
            for a in dataset.accounts {
                try run("INSERT INTO accounts VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [
                    .text(user), .text(a.accountId), .text(a.institution), .text(a.kind), .text(a.assetOrLiability.rawValue),
                    a.openingBalanceCents.map(SQLValue.int) ?? .null, .int(a.balanceCents), .text(a.asOf),
                    a.sourceId.map(SQLValue.text) ?? .null, .text(Self.origin(a))])
            }
            let owned = Set(dataset.accounts.map(\.accountId))
            for t in dataset.transactions where owned.contains(t.accountId) {
                try run("INSERT OR REPLACE INTO transactions VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [
                    .text(user), .text(t.sourceId ?? t.transactionId), .text(t.transactionId), .text(t.accountId),
                    .text(t.postedAt), .text(Self.localDate(t.postedAt, tz) ?? String(t.postedAt.prefix(10))),
                    .int(t.signedAmountCents), .text(t.merchant), t.category.map(SQLValue.text) ?? .null, .int(t.pending ? 1 : 0),
                    t.transferPairId.map(SQLValue.text) ?? .null, t.refundOf.map(SQLValue.text) ?? .null,
                    t.sourceId.map(SQLValue.text) ?? .null])
            }
        }
    }

    /// Statement accounts imported on this phone in an earlier session, with their transactions.
    public func importedAccounts(userID: String) throws -> [(account: Account, transactions: [Transaction])] {
        // FWMCore records have no public memberwise initializers; rebuild them through the shared snake_case wire format.
        let accounts: [Account] = try rows("SELECT account_id, institution, kind, side, opening_cents, balance_cents, as_of, source_id FROM accounts WHERE user_id = ? AND origin IN ('csv', 'linked') ORDER BY account_id", [.text(userID)]).map { r in
            try Self.decode(["account_id": r.text(0), "institution": r.text(1), "kind": r.text(2), "asset_or_liability": r.text(3),
                             "opening_balance_cents": r.optionalInt(4), "balance_cents": r.int(5), "as_of": r.text(6), "source_id": r.optionalText(7)])
        }
        return try accounts.map { a in
            let txns = try rows("""
                SELECT transaction_id, account_id, posted_at, amount_cents, merchant, category, pending, transfer_pair_id, refund_of, source_id
                FROM transactions WHERE user_id = ? AND account_id = ? ORDER BY posted_at, transaction_id
                """, [.text(userID), .text(a.accountId)]).map { r -> Transaction in
                try Self.decode(["transaction_id": r.text(0), "account_id": r.text(1), "posted_at": r.text(2), "signed_amount_cents": r.int(3),
                                 "merchant": r.text(4), "category": r.optionalText(5), "pending": r.int(6) != 0, "transfer_pair_id": r.optionalText(7),
                                 "refund_of": r.optionalText(8), "source_id": r.optionalText(9)])
            }
            return (a, txns)
        }
    }

    // MARK: user edits

    /// A category the user chose for a transaction. Reapplied to the dataset on launch, so it survives relaunch.
    public func setCategory(_ category: String, transactionIDs: [String], userID: String) throws {
        try transaction {
            for id in transactionIDs {
                try run("INSERT OR REPLACE INTO category_overrides VALUES (?, ?, ?)", [.text(userID), .text(id), .text(category)])
            }
        }
    }

    public func categoryOverrides(userID: String) throws -> [String: String] {
        Dictionary(try rows("SELECT transaction_id, category FROM category_overrides WHERE user_id = ?", [.text(userID)]).map { ($0.text(0), $0.text(1)) },
                   uniquingKeysWith: { _, b in b })
    }

    // MARK: activity journal

    public func record(_ event: LedgerEvent, userID: String) throws {
        let details = String(data: try JSONSerialization.data(withJSONObject: event.details, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
        try run("INSERT INTO events (user_id, kind, summary, occurred_at, details) VALUES (?, ?, ?, ?, ?)",
                [.text(userID), .text(event.kind), .text(event.summary), .double(event.occurredAt.timeIntervalSince1970), .text(details)])
    }

    /// Most recent first.
    public func events(userID: String, kinds: Set<String>? = nil, matching text: String? = nil, limit: Int = 50) throws -> [LedgerEvent] {
        var sql = "SELECT kind, summary, occurred_at, details FROM events WHERE user_id = ?"
        var args: [SQLValue] = [.text(userID)]
        if let kinds, !kinds.isEmpty { sql += " AND kind IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ", ")))"; args += kinds.sorted().map(SQLValue.text) }
        if let like = Self.likePattern(text) { sql += " AND (summary LIKE ? ESCAPE '\\' OR kind LIKE ? ESCAPE '\\')"; args += [.text(like), .text(like)] }
        sql += " ORDER BY seq DESC LIMIT ?"; args.append(.int(max(1, min(limit, 200))))
        return try rows(sql, args).map { r in
            let details = (try? JSONSerialization.jsonObject(with: Data(r.text(3).utf8))) as? [String: String] ?? [:]
            return LedgerEvent(kind: r.text(0), summary: r.text(1), occurredAt: Date(timeIntervalSince1970: r.double(2)), details: details)
        }
    }

    // MARK: agent queries

    public func query(_ request: LedgerRequest, scope: CoreScope) async throws -> CoreToolOutput {
        let from = try Self.validDate(request.from), to = try Self.validDate(request.to)
        if let from, let to, from > to { throw ToolError(.invalidArguments, "The start date is after the end date.") }
        let limit = max(1, min(request.limit, 25))
        let like = Self.likePattern(request.text)
        guard !scope.accountIDs.isEmpty || request.operation == .activity else {
            throw ToolError(.authRequired, "No accounts are in scope for this conversation.")
        }
        // Owned accounts only; the host's scope, not the model, decides which.
        var filter = "t.user_id = ? AND t.account_id IN (\(Array(repeating: "?", count: scope.accountIDs.count).joined(separator: ", ")))"
        var args: [SQLValue] = [.text(scope.userID)] + scope.accountIDs.sorted().map(SQLValue.text)
        if let from { filter += " AND t.posted_date >= ?"; args.append(.text(from)) }
        if let to { filter += " AND t.posted_date <= ?"; args.append(.text(to)) }
        let dated = [from.map { "from \($0)" }, to.map { "to \($0)" }].compactMap { $0 }.joined(separator: " ")
        /// The period an answer covers, read after the filters are final, so an unfiltered total isn't reported as one month.
        func window() throws -> String {
            guard dated.isEmpty else { return dated }
            let span = try rows("SELECT min(t.posted_date), max(t.posted_date) FROM transactions t WHERE \(filter)", args)[0]
            return span.optionalText(0).map { "with no date filter (all stored transactions, \($0) to \(span.text(1)))" } ?? "with no date filter"
        }
        let spending = "t.pending = 0 AND t.transfer_pair_id IS NULL AND NOT (COALESCE(t.category, '') = 'Income' AND t.amount_cents > 0)"
        var lines: [String] = []
        var sources: [String] = []
        var imported = false
        var chart: ChatChart?

        switch request.operation {
        case .search:
            if let like { filter += " AND (t.merchant LIKE ? ESCAPE '\\' OR t.category LIKE ? ESCAPE '\\')"; args += [.text(like), .text(like)] }
            let totals = try rows("SELECT count(*), COALESCE(sum(t.amount_cents), 0), COALESCE(sum(CASE WHEN \(spending) THEN -t.amount_cents ELSE 0 END), 0) FROM transactions t WHERE \(filter)", args)[0]
            let found = try rows("""
                SELECT t.transaction_id, t.posted_date, t.merchant, t.category, t.amount_cents, t.pending, t.transfer_pair_id, a.institution, a.kind, a.origin
                FROM transactions t JOIN accounts a ON a.user_id = t.user_id AND a.account_id = t.account_id
                WHERE \(filter) ORDER BY t.posted_at DESC, t.transaction_id LIMIT ?
                """, args + [.int(limit)])
            lines.append("\(totals.int(0)) matching transactions\(request.text.map { " for \"\($0)\"" } ?? "") \(try window()). Net \(CoreDatasetTools.money(totals.int(1))); spending (excluding transfers, pending and income) \(CoreDatasetTools.money(totals.int(2))).")
            if totals.int(0) > found.count { lines.append("Showing the latest \(found.count).") }
            // Spending per month when the matches span more than one month.
            let months = try rows("SELECT substr(t.posted_date, 1, 7) AS month, sum(CASE WHEN \(spending) THEN -t.amount_cents ELSE 0 END) FROM transactions t WHERE \(filter) GROUP BY month ORDER BY month", args)
            if months.count > 1 {
                chart = ChatChart(title: "\(request.text.map { "\($0) s" } ?? "S")pending by month", style: .columns,
                                  points: months.map { .init(label: Self.monthLabel($0.text(0)), cents: $0.int(1)) })
            }
            for r in found {
                sources.append(r.text(0)); imported = imported || r.text(9) != "dataset"
                let tags = [r.optionalText(3), r.int(5) != 0 ? "pending" : nil, r.optionalText(6) != nil ? "transfer" : nil, Self.originTag(r.text(9))].compactMap { $0 }
                lines.append("- \(r.text(1)) \(r.text(2)) \(CoreDatasetTools.money(r.int(4))) · \(r.text(7)) \(r.text(8).replacingOccurrences(of: "_", with: " "))\(tags.isEmpty ? "" : " · " + tags.joined(separator: ", "))")
            }
        case .categories, .merchants:
            let column = request.operation == .categories ? "COALESCE(t.category, 'Uncategorized')" : "t.merchant"
            if let like { filter += " AND \(column) LIKE ? ESCAPE '\\'"; args.append(.text(like)) }
            let grouped = try rows("""
                SELECT \(column) AS label, sum(-t.amount_cents) AS spent, count(*) AS n
                FROM transactions t WHERE \(filter) AND \(spending) GROUP BY label ORDER BY spent DESC, label LIMIT ?
                """, args + [.int(limit)])
            let total = grouped.reduce(0) { $0 + $1.int(1) }
            lines.append("Spending by \(request.operation == .categories ? "category" : "merchant") \(try window()) (transfers, pending and income excluded):")
            for r in grouped { lines.append("- \(r.text(0)): \(CoreDatasetTools.money(r.int(1))) in \(r.int(2)) transaction\(r.int(2) == 1 ? "" : "s")") }
            lines.append("Listed total \(CoreDatasetTools.money(total)).")
            if !grouped.isEmpty {
                chart = ChatChart(title: "Spending by \(request.operation == .categories ? "category" : "merchant")", style: .bars,
                                  points: grouped.prefix(10).map { .init(label: $0.text(0), cents: $0.int(1)) })
            }
            sources = try rows("SELECT t.transaction_id FROM transactions t WHERE \(filter) AND \(spending) ORDER BY t.posted_at DESC LIMIT 50", args).map { $0.text(0) }
        case .accounts:
            var accountFilter = "user_id = ? AND account_id IN (\(Array(repeating: "?", count: scope.accountIDs.count).joined(separator: ", ")))"
            var accountArgs: [SQLValue] = [.text(scope.userID)] + scope.accountIDs.sorted().map(SQLValue.text)
            if let like { accountFilter += " AND (institution LIKE ? ESCAPE '\\' OR kind LIKE ? ESCAPE '\\')"; accountArgs += [.text(like), .text(like)] }
            for r in try rows("SELECT account_id, institution, kind, side, balance_cents, as_of, origin FROM accounts WHERE \(accountFilter) ORDER BY side, institution, kind", accountArgs) {
                sources.append(r.text(0)); imported = imported || r.text(6) != "dataset"
                lines.append("- \(r.text(1)) \(r.text(2).replacingOccurrences(of: "_", with: " ")): \(CoreDatasetTools.money(r.int(4)))\(r.text(3) == "liability" ? " owed" : "") as of \(r.text(5).prefix(10))\(Self.originTag(r.text(6)).map { " · \($0)" } ?? "")")
            }
            if lines.isEmpty { lines.append("No matching accounts.") }
        case .activity:
            let found = try events(userID: scope.userID, matching: request.text, limit: limit)
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
            lines.append(found.isEmpty ? "No recorded app activity\(request.text.map { " matching \"\($0)\"" } ?? "")." : "Recent app activity on this phone, newest first:")
            for e in found { lines.append("- \(formatter.string(from: e.occurredAt)) UTC · \(e.summary)") }
            lines.append("Activity is what the user did in Lana. Simulated actions moved no money.")
        }

        let digest = SHA256.hash(data: Data("\(request.operation.rawValue)|\(request.text ?? "")|\(from ?? "")|\(to ?? "")|\(limit)|\(scope.accountIDs.sorted())".utf8))
            .prefix(6).map { String(format: "%02x", $0) }.joined()
        let provenance = Provenance(resultId: "ledger:\(request.operation.rawValue):\(scope.datasetVersion):\(digest)", datasetVersion: scope.datasetVersion,
            dataMode: imported ? .cached : .fixture, asOf: ISO8601DateFormatter().string(from: Date()), sourceIds: Array(sources.prefix(50)),
            engineVersion: Self.engineVersion)
        return CoreToolOutput(replyText: lines.joined(separator: "\n"), provenance: request.operation == .activity ? nil : provenance, chart: chart)
    }

    // MARK: helpers

    /// Statement imports (`csv:`) and SimpleFIN links (`sfin:`) are the user's own additions and persist here.
    static func isImported(_ a: Account) -> Bool { a.sourceId.map { $0.hasPrefix("csv:") || $0.hasPrefix("sfin:") } ?? false }

    static func origin(_ a: Account) -> String {
        if a.sourceId?.hasPrefix("csv:") == true { return "csv" }
        if a.sourceId?.hasPrefix("sfin:") == true { return "linked" }
        return "dataset"
    }
    static func originTag(_ origin: String) -> String? { ["csv": "imported", "linked": "linked via SimpleFIN"][origin] }

    /// "2026-09" as "Sep 2026".
    static func monthLabel(_ ym: String) -> String {
        let names = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard ym.count == 7, let m = Int(ym.suffix(2)), (1...12).contains(m) else { return ym }
        return "\(names[m - 1]) \(ym.prefix(4))"
    }

    private static func decode<T: Decodable>(_ fields: [String: Any?]) throws -> T {
        let present = fields.compactMapValues { $0 }
        return try FWMJSON.decoder.decode(T.self, from: JSONSerialization.data(withJSONObject: present))
    }

    public static func validDate(_ raw: String?) throws -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard raw.count == 10, let d = f.date(from: raw), f.string(from: d) == raw else {
            throw ToolError(.invalidArguments, "Use dates like 2026-09-01.")
        }
        return raw
    }

    public static func localDate(_ iso: String, _ tz: TimeZone) -> String? {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime]
        guard let d = parser.date(from: iso) else { return nil }
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// Words to a LIKE pattern with wildcards escaped; nil matches everything.
    static func likePattern(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        let escaped = String(t.prefix(80)).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        return "%\(escaped)%"
    }

    enum SQLValue: Sendable { case text(String), int(Int), double(Double), null }

    struct Row {
        let values: [SQLValue]
        func text(_ i: Int) -> String { if case .text(let s) = values[i] { return s }; if case .int(let n) = values[i] { return String(n) }; return "" }
        func optionalText(_ i: Int) -> String? { if case .null = values[i] { return nil }; return text(i) }
        func int(_ i: Int) -> Int { switch values[i] { case .int(let n): return n; case .double(let d): return Int(d); case .text(let s): return Int(s) ?? 0; case .null: return 0 } }
        func optionalInt(_ i: Int) -> Int? { if case .null = values[i] { return nil }; return int(i) }
        func double(_ i: Int) -> Double { switch values[i] { case .double(let d): return d; case .int(let n): return Double(n); default: return 0 } }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func exec(_ handle: OpaquePointer?, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw FinanceAIError.unavailable("Local ledger error: \(message)")
        }
    }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw FinanceAIError.unavailable("Local ledger error: \(String(cString: sqlite3_errmsg(db)))")
        }
        for (i, value) in args.enumerated() {
            let n = Int32(i + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(stmt, n, s, -1, Self.transient)
            case .int(let v): sqlite3_bind_int64(stmt, n, sqlite3_int64(v))
            case .double(let v): sqlite3_bind_double(stmt, n, v)
            case .null: sqlite3_bind_null(stmt, n)
            }
        }
        return stmt
    }

    private func run(_ sql: String, _ args: [SQLValue] = []) throws {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw FinanceAIError.unavailable("Local ledger error: \(String(cString: sqlite3_errmsg(db)))") }
    }

    private func rows(_ sql: String, _ args: [SQLValue] = []) throws -> [Row] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [Row] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw FinanceAIError.unavailable("Local ledger error: \(String(cString: sqlite3_errmsg(db)))") }
            out.append(Row(values: (0..<sqlite3_column_count(stmt)).map { c in
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: return .int(Int(sqlite3_column_int64(stmt, c)))
                case SQLITE_FLOAT: return .double(sqlite3_column_double(stmt, c))
                case SQLITE_NULL: return .null
                default: return .text(String(cString: sqlite3_column_text(stmt, c)))
                }
            }))
        }
        return out
    }

    private func transaction(_ body: () throws -> Void) throws {
        try Self.exec(db, "BEGIN IMMEDIATE")
        do { try body(); try Self.exec(db, "COMMIT") } catch { try? Self.exec(db, "ROLLBACK"); throw error }
    }
}
