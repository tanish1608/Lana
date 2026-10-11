import Foundation
import FWMCore

/// The split assignment the voice instruction resolves to in seed-v1 (`split_example`).
struct SplitExample: Decodable {
    var receiptId: String
    var payerId: String
    var assignments: [String: [String]]
}

private struct SeedExtras: Decodable { var splitExample: SplitExample? }

/// Fixture-backed source for the feature screens. Engines compute every number; this only loads inputs.
/// A live build swaps in provider-backed datasets with the same `Dataset` shape.
public final class DemoStore {
    public let dataset: Dataset
    let splitExample: SplitExample?

    public init(fixtureURL: URL) throws {
        let data = try Data(contentsOf: fixtureURL)
        dataset = try FWMJSON.decoder.decode(Dataset.self, from: data)
        splitExample = (try? FWMJSON.decoder.decode(SeedExtras.self, from: data))?.splitExample
    }

    /// fixtures/seed-v1.json in this checkout. Works for Xcode previews and `swift run` on a dev Mac;
    /// an app bundle should pass a bundled copy's URL instead.
    public static func repoSeedURL(file: String = #filePath) -> URL {
        var u = URL(fileURLWithPath: file)
        for _ in 0..<5 { u.deleteLastPathComponent() } // FWMFeatureUI.swift → Sources → package → Packages → repo
        return u.appendingPathComponent("fixtures/seed-v1.json")
    }

    public static func repoSeed() -> DemoStore? { try? DemoStore(fixtureURL: repoSeedURL()) }

    /// Months that have transactions, plus the demo clock's month (in progress).
    var periods: [String] {
        var set = Set(dataset.transactions.compactMap { Self.month($0.postedAt) })
        if let c = dataset.demoClock, let m = Self.month(c) { set.insert(m) }
        return set.sorted()
    }
    var snapshotPeriod: String { Self.month(dataset.asOf) ?? "2026-09" }

    func moneyView(_ period: String) -> Result<MoneyView, ToolError> {
        do { return .success(try MoneyEngine.moneyView(dataset, period: period)) }
        catch let e as ToolError { return .failure(e) }
        catch { return .failure(ToolError(.invalidArguments, error.localizedDescription)) }
    }

    func transactions(_ ids: [String]) -> [Transaction] {
        let byId = Dictionary(dataset.transactions.map { ($0.transactionId, $0) }, uniquingKeysWith: { _, b in b })
        return ids.compactMap { byId[$0] }
    }

    static func month(_ iso: String) -> String? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: iso) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let c = cal.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year!, c.month!)
    }

    static func monthName(_ period: String, short: Bool = false) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        f.timeZone = TimeZone(identifier: "America/Los_Angeles")
        guard let d = f.date(from: period) else { return period }
        f.dateFormat = short ? "MMM" : "MMMM yyyy"
        return f.string(from: d)
    }

    static func day(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: iso) else { return iso }
        let o = DateFormatter()
        o.dateFormat = "MMM d"
        o.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return o.string(from: d)
    }
}
