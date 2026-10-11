import Foundation

// Fixture and normalized-provider records (SRS v2 section 8). All amounts are integer USD cents.
// Sign convention (DATA-01): money entering an account is positive, money leaving is negative.
// Liability balances are positive amounts owed.

public struct UserPrefs: Codable, Sendable {
    public var userId: String
    public var displayName: String?
    public var timezone: String
    public var currency: String
    public var brandLocks: [String]
    public var dietaryRules: [String]
    public var savingsGoalCents: Int
    public var preferencesVersion: Int
}

public struct Account: Codable, Sendable, Equatable {
    public enum Side: String, Codable, Sendable { case asset, liability }
    public var accountId: String
    public var institution: String
    public var kind: String
    public var assetOrLiability: Side
    public var openingBalanceCents: Int?
    public var balanceCents: Int
    public var asOf: String
    public var sourceId: String?
}

public struct Transaction: Codable, Sendable, Equatable {
    public var transactionId: String
    public var accountId: String
    public var postedAt: String
    public var signedAmountCents: Int
    public var merchant: String
    public var category: String?
    public var pending: Bool
    public var transferPairId: String?
    public var refundOf: String?
    public var sourceId: String?
}

public struct ReceiptItem: Codable, Sendable, Equatable {
    public var itemId: String
    public var description: String
    public var quantity: Int
    public var extendedPriceCents: Int
    public var ocrConfidence: Double?
}

public struct Receipt: Codable, Sendable, Equatable {
    public var receiptId: String
    public var merchant: String?
    public var date: String?
    public var items: [ReceiptItem]
    public var subtotalCents: Int
    public var taxCents: Int
    public var tipCents: Int
    public var totalCents: Int
}

public struct Contact: Codable, Sendable, Equatable {
    public var contactId: String
    public var reviewedName: String
    public var phone: String
    public var venmoHandle: String?
    public var isSelf: Bool?
}

public struct Dataset: Codable, Sendable {
    public var datasetVersion: String
    public var dataMode: DataMode
    public var asOf: String
    public var demoClock: String?
    public var user: UserPrefs
    public var accounts: [Account]
    public var transactions: [Transaction]
    public var receipts: [Receipt]?
    public var contacts: [Contact]?

    public static func load(from url: URL) throws -> Dataset {
        try FWMJSON.decoder.decode(Dataset.self, from: Data(contentsOf: url))
    }
}
