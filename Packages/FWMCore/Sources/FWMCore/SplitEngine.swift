import Foundation

// prepare_split (SRS v2 section 5). Exact cents: shares always sum to the receipt total.

public enum TaxTipRule: String, Codable, Sendable {
    /// Tax and tip follow each person's item subtotal.
    case proportional
    /// Tax and tip split evenly across participants.
    case equal
    /// Ignore items; split the whole total evenly.
    case equalTotal = "equal_total"
}

public struct Share: Codable, Sendable, Equatable {
    public var contactId: String
    public var itemsCents: Int
    public var taxTipCents: Int
    public var totalCents: Int
}

public struct ReimbursementDraft: Codable, Sendable, Equatable {
    public var contactId: String
    public var reviewedName: String
    public var amountCents: Int
    public var venmoHandle: String?
    public var note: String
}

public struct SplitResult: Codable, Sendable, Equatable {
    public var provenance: Provenance
    public var receiptId: String
    public var payerId: String
    public var rule: TaxTipRule
    public var shares: [Share]
    /// Everyone except the payer (SPLIT-04).
    public var requests: [ReimbursementDraft]
    public var outstandingCents: Int
}

public enum SplitEngine {
    public static let version = "split-1.0"

    public static func prepareSplit(receipt: Receipt, assignments: [String: [String]], payerId: String,
                                    contacts: [Contact], rule: TaxTipRule = .proportional,
                                    datasetVersion: String = "seed-v1", dataMode: DataMode = .fixture) throws -> SplitResult {
        // SPLIT-03: block until the receipt adds up within one cent.
        let itemsSum = receipt.items.reduce(0) { $0 + $1.extendedPriceCents }
        guard abs(itemsSum - receipt.subtotalCents) <= 1,
              abs(receipt.subtotalCents + receipt.taxCents + receipt.tipCents - receipt.totalCents) <= 1 else {
            throw ToolError(.receiptMismatch, "The receipt doesn't add up. Check the items, tax and tip before I split it.")
        }
        // SPLIT-05: only reviewed contacts can receive a share.
        let roster = Dictionary(uniqueKeysWithValues: contacts.map { ($0.contactId, $0) })
        let people = Array(Set(assignments.values.flatMap { $0 } + [payerId])).sorted()
        if let unknown = people.first(where: { roster[$0] == nil }) {
            throw ToolError(.ambiguousContact, "I don't know who \(unknown) is. Pick them from your contacts first.")
        }
        if let missing = receipt.items.first(where: { (assignments[$0.itemId] ?? []).isEmpty }) {
            throw ToolError(.invalidArguments, "Who had the \(missing.description)?")
        }

        var items: [String: Int] = Dictionary(uniqueKeysWithValues: people.map { ($0, 0) })
        var taxTip: [String: Int] = items
        let taxTipTotal = receipt.taxCents + receipt.tipCents

        if rule == .equalTotal {
            let even = allocate(receipt.totalCents, weights: people.map { _ in 1 })
            for (i, p) in people.enumerated() { items[p] = even[i] }
        } else {
            for item in receipt.items {
                let who = assignments[item.itemId]!.sorted()
                let parts = allocate(item.extendedPriceCents, weights: who.map { _ in 1 })
                for (i, p) in who.enumerated() { items[p, default: 0] += parts[i] }
            }
            let weights = rule == .proportional ? people.map { items[$0]! } : people.map { _ in 1 }
            let parts = allocate(taxTipTotal, weights: weights)
            for (i, p) in people.enumerated() { taxTip[p] = parts[i] }
        }

        let shares = people.map { Share(contactId: $0, itemsCents: items[$0]!, taxTipCents: taxTip[$0]!, totalCents: items[$0]! + taxTip[$0]!) }
        assert(shares.reduce(0) { $0 + $1.totalCents } == (rule == .equalTotal ? receipt.totalCents : receipt.subtotalCents + taxTipTotal))
        let payerName = roster[payerId]!.reviewedName
        let requests = shares.filter { $0.contactId != payerId }.map { s in
            ReimbursementDraft(contactId: s.contactId, reviewedName: roster[s.contactId]!.reviewedName, amountCents: s.totalCents,
                               venmoHandle: roster[s.contactId]!.venmoHandle,
                               note: "\(receipt.merchant ?? "Dinner") \(receipt.date ?? ""): your share to \(payerName)".trimmingCharacters(in: .whitespaces))
        }
        let provenance = Provenance(resultId: "split:\(receipt.receiptId):\(rule.rawValue)", datasetVersion: datasetVersion, dataMode: dataMode,
                                    asOf: receipt.date ?? "", sourceIds: [receipt.receiptId], engineVersion: version)
        return SplitResult(provenance: provenance, receiptId: receipt.receiptId, payerId: payerId, rule: rule, shares: shares,
                           requests: requests, outstandingCents: requests.reduce(0) { $0 + $1.amountCents })
    }

    /// Largest-remainder allocation: integer parts proportional to weights that sum exactly to `total`.
    /// Ties go to the earlier index, so the result is stable for a sorted participant list.
    public static func allocate(_ total: Int, weights: [Int]) -> [Int] {
        let w = weights.reduce(0, +)
        guard w > 0 else { return allocate(total, weights: weights.map { _ in 1 }) }
        var parts = weights.map { total * $0 / w }
        let remainders = weights.enumerated().map { (i: $0.offset, r: total * $0.element % w) }
        var left = total - parts.reduce(0, +)
        for (i, _) in remainders.sorted(by: { ($0.r, -$0.i) > ($1.r, -$1.i) }) where left > 0 {
            parts[i] += 1
            left -= 1
        }
        return parts
    }
}
