import Foundation
import CryptoKit

// Aggregator adapters (SRS v2 section 8). Every provider produces the same normalized Dataset, so the engines never
// know where the numbers came from; provenance and ProviderStatus say that instead.

public struct ProviderStatus: Codable, Sendable, Equatable {
    public var provider: String
    public var dataMode: DataMode
    public var asOf: String
    public var accountCount: Int
    public var transactionCount: Int
    public var matchedTransfers: Int
    /// Things the user should review: unmatched transfers, skipped rows.
    public var warnings: [String]
}

public protocol AccountProvider: Sendable {
    var name: String { get }
    func fetch() throws -> (Dataset, ProviderStatus)
}

/// The canonical demo data.
public struct FixtureProvider: AccountProvider {
    public let url: URL
    public var name: String { "fixture" }
    public init(url: URL) { self.url = url }

    public func fetch() throws -> (Dataset, ProviderStatus) {
        let ds = try Dataset.load(from: url)
        let pairs = Set(ds.transactions.compactMap(\.transferPairId)).count
        return (ds, ProviderStatus(provider: name, dataMode: ds.dataMode, asOf: ds.asOf, accountCount: ds.accounts.count,
                                   transactionCount: ds.transactions.count, matchedTransfers: pairs, warnings: []))
    }
}

/// One account's statement export, as downloaded from the bank's website.
public struct CSVStatement: Sendable {
    public var accountId: String
    public var institution: String
    public var kind: String
    public var side: Account.Side
    /// The balance the bank shows now. CSV exports have no opening balance, so this account is not reconciled.
    public var balanceCents: Int
    public var csv: String

    public init(accountId: String, institution: String, kind: String, side: Account.Side, balanceCents: Int, csv: String) {
        self.accountId = accountId
        self.institution = institution
        self.kind = kind
        self.side = side
        self.balanceCents = balanceCents
        self.csv = csv
    }
}

/// Imports bank CSV exports on the phone. No account, no aggregator login, nothing leaves the device.
/// Columns (case-insensitive): Date, Description, Amount, and optionally Category and Status (Pending/Posted).
/// Exports carry no transfer links, so the importer pairs them itself (DATA-02).
public struct BankCSVProvider: AccountProvider {
    public var statements: [CSVStatement]
    public var user: UserPrefs
    public var asOf: String
    public var datasetVersion: String
    /// How far apart the two legs of one transfer may post.
    public var transferWindowDays: Int = 3
    public var name: String { "bank_csv" }

    public init(statements: [CSVStatement], user: UserPrefs, asOf: String, datasetVersion: String = "csv-import") {
        self.statements = statements
        self.user = user
        self.asOf = asOf
        self.datasetVersion = datasetVersion
    }

    public func fetch() throws -> (Dataset, ProviderStatus) {
        var accounts: [Account] = []
        var txns: [Transaction] = []
        var warnings: [String] = []
        for st in statements {
            accounts.append(Account(accountId: st.accountId, institution: st.institution, kind: st.kind, assetOrLiability: st.side,
                                    openingBalanceCents: nil, balanceCents: st.balanceCents, asOf: asOf, sourceId: "csv:\(st.accountId)"))
            let rows = CSV.parse(st.csv)
            guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespaces).lowercased() }) else { continue }
            func col(_ names: String...) -> Int? { header.firstIndex { names.contains($0) } }
            guard let iDate = col("date", "posting date", "transaction date", "posted date"),
                  let iDesc = col("description", "merchant", "payee", "name"),
                  let iAmt = col("amount") else {
                throw ToolError(.invalidArguments, "\(st.institution) \(st.kind): the CSV needs Date, Description and Amount columns.")
            }
            let iCat = col("category"), iStatus = col("status")
            var seen: [String: Int] = [:]
            for (n, r) in rows.dropFirst().enumerated() where r.count > max(iDate, iDesc, iAmt) {
                guard let date = CSV.isoDate(r[iDate]), let cents = CSV.cents(r[iAmt]) else {
                    warnings.append("\(st.institution) \(st.kind) row \(n + 2) skipped: unreadable date or amount.")
                    continue
                }
                let desc = r[iDesc].trimmingCharacters(in: .whitespaces)
                // Stable id: the same row in a re-downloaded export dedupes (DATA-03); identical rows stay distinct.
                let key = "\(st.accountId)|\(date)|\(desc)|\(cents)"
                let occurrence = seen[key, default: 0]
                seen[key] = occurrence + 1
                let hash = SHA256.hash(data: Data("\(key)|\(occurrence)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
                let category = iCat.flatMap { $0 < r.count ? r[$0].trimmingCharacters(in: .whitespaces) : nil }.flatMap { $0.isEmpty ? nil : $0 }
                let pending = iStatus.map { $0 < r.count && r[$0].lowercased().contains("pending") } ?? false
                txns.append(Transaction(transactionId: "csv_\(hash)", accountId: st.accountId, postedAt: "\(date)T12:00:00-07:00",
                                        signedAmountCents: cents, merchant: desc, category: category, pending: pending,
                                        transferPairId: nil, refundOf: nil, sourceId: "csv:\(st.accountId):\(hash)"))
            }
        }
        let matched = pairTransfers(&txns, warnings: &warnings)
        let ds = Dataset(datasetVersion: datasetVersion, dataMode: .live, asOf: asOf, demoClock: nil, user: user,
                         accounts: accounts, transactions: txns, receipts: nil, contacts: nil)
        return (ds, ProviderStatus(provider: name, dataMode: .live, asOf: asOf, accountCount: accounts.count,
                                   transactionCount: txns.count, matchedTransfers: matched, warnings: warnings))
    }

    /// Pairs each transfer outflow with an equal inflow in a different imported account within the window, earliest first.
    func pairTransfers(_ txns: inout [Transaction], warnings: inout [String]) -> Int {
        func isTransfer(_ t: Transaction) -> Bool {
            let c = (t.category ?? "").lowercased(), m = t.merchant.lowercased()
            return c == "transfer" || (c.contains("payment") && c.contains("card")) || m.contains("transfer to") || m.contains("transfer from")
                || m.contains("card payment") || m.contains("autopay")
        }
        func day(_ t: Transaction) -> Int { Int((CSV.date(t.postedAt)?.timeIntervalSince1970 ?? 0) / 86_400) }
        let candidates = txns.indices.filter { isTransfer(txns[$0]) && !txns[$0].pending }.sorted { txns[$0].postedAt < txns[$1].postedAt }
        var used = Set<Int>()
        var pairs = 0
        for i in candidates where txns[i].signedAmountCents < 0 && !used.contains(i) {
            guard let j = candidates.first(where: { j in
                !used.contains(j) && txns[j].accountId != txns[i].accountId && txns[j].signedAmountCents == -txns[i].signedAmountCents
                    && abs(day(txns[j]) - day(txns[i])) <= transferWindowDays
            }) else { continue }
            pairs += 1
            let id = "csvpair_\(pairs)"
            txns[i].transferPairId = id
            txns[j].transferPairId = id
            used.formUnion([i, j])
        }
        let unmatched = candidates.filter { !used.contains($0) }
        // A lone pair id makes the engine exclude the leg as unmatchedTransfer instead of counting it as spending.
        for (n, i) in unmatched.enumerated() { txns[i].transferPairId = "csvunmatched_\(n + 1)" }
        if !unmatched.isEmpty {
            warnings.append("\(unmatched.count) transfer(s) had no matching leg in the imported accounts and are left out of spending: "
                + unmatched.prefix(3).map { "\(txns[$0].merchant) \(txns[$0].postedAt.prefix(10))" }.joined(separator: "; "))
        }
        return pairs
    }
}

enum CSV {
    /// RFC 4180-ish: quoted fields, doubled quotes, CRLF.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        func endField() { row.append(field); field = "" }
        func endRow() { endField(); if !(row.count == 1 && row[0].isEmpty) { rows.append(row) }; row = [] }
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": quoted = true
                case ",": endField()
                case "\n", "\r\n": endRow()
                case "\r": break
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// "-12.34", "12.34-", "(12.34)", "$1,234.56", "−5" → cents, without floating point.
    static func cents(_ raw: String) -> Int? {
        var s = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{2212}", with: "-")
        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") { negative = true; s = String(s.dropFirst().dropLast()) }
        if s.hasSuffix("-") { negative = true; s = String(s.dropLast()) }
        if s.hasPrefix("-") { negative.toggle(); s = String(s.dropFirst()) }
        s = s.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), let whole = Int(parts[0].isEmpty ? "0" : parts[0]) else { return nil }
        var frac = 0
        if parts.count == 2 {
            let f = String(parts[1].prefix(2)).padding(toLength: 2, withPad: "0", startingAt: 0)
            guard let v = Int(f), parts[1].allSatisfy(\.isNumber) else { return nil }
            frac = v
        }
        let value = whole * 100 + frac
        return negative ? -value : value
    }

    /// "2026-09-01" or "09/01/2026" (US) → "2026-09-01".
    static func isoDate(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil { return String(s.prefix(10)) }
        let p = s.split(separator: "/")
        guard p.count == 3, let m = Int(p[0]), let d = Int(p[1]), var y = Int(p[2].prefix(4)) else { return nil }
        if y < 100 { y += 2000 }
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    static func date(_ iso: String) -> Date? {
        let f = ISO8601DateFormatter()
        return f.date(from: iso)
    }
}
