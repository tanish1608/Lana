import SwiftUI
import FWMCore
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// US institutions Lana recognises: display name, website, brand colour, logo and the account products shown in the app.
/// Logos are the institutions' App Store icons, bundled so the screen works offline. Matching is on the dataset's
/// `institution` string, so a provider or CSV import that uses one of these names gets the same mark.
struct Institution: Identifiable, Hashable, Sendable {
    enum Category: String, CaseIterable, Sendable {
        case bank = "Banks", card = "Credit cards", investing = "Investing", loans = "Loans", payments = "Payments"
    }
    let id: String
    let name: String
    let domain: String
    let category: Category
    let brand: UInt32
    let kinds: [String]
    var products: [String: String] = [:]
    var aliases: [String] = []

    var color: Color { Color(light: brand, dark: brand) }

    func product(_ kind: String) -> String { products[kind] ?? "\(name) \(AccountKind.name(kind))" }

    static let all: [Institution] = [
        .init(id: "chase", name: "Chase", domain: "chase.com", category: .bank, brand: 0x117ACA, kinds: ["checking", "savings", "credit_card"],
              products: ["checking": "Chase Total Checking", "savings": "Chase Savings", "credit_card": "Chase Freedom Unlimited"], aliases: ["jpmorgan chase", "chase bank"]),
        .init(id: "bank_of_america", name: "Bank of America", domain: "bankofamerica.com", category: .bank, brand: 0xE31837, kinds: ["checking", "savings", "credit_card"],
              products: ["checking": "Advantage Plus Banking", "savings": "Advantage Savings", "credit_card": "Customized Cash Rewards"], aliases: ["bofa"]),
        .init(id: "wells_fargo", name: "Wells Fargo", domain: "wellsfargo.com", category: .bank, brand: 0xD71E28, kinds: ["checking", "savings", "credit_card"],
              products: ["checking": "Everyday Checking", "savings": "Way2Save Savings", "credit_card": "Active Cash Card"]),
        .init(id: "capital_one", name: "Capital One", domain: "capitalone.com", category: .card, brand: 0xD03027, kinds: ["credit_card", "checking", "savings"],
              products: ["credit_card": "Quicksilver Rewards", "checking": "360 Checking", "savings": "360 Performance Savings"]),
        .init(id: "citi", name: "Citi", domain: "citi.com", category: .card, brand: 0x056DAE, kinds: ["credit_card", "checking", "savings"],
              products: ["credit_card": "Citi Double Cash", "checking": "Citi Regular Checking", "savings": "Citi Savings"], aliases: ["citibank"]),
        .init(id: "american_express", name: "American Express", domain: "americanexpress.com", category: .card, brand: 0x006FCF, kinds: ["credit_card", "savings"],
              products: ["credit_card": "Blue Cash Everyday", "savings": "High Yield Savings"], aliases: ["amex"]),
        .init(id: "discover", name: "Discover", domain: "discover.com", category: .card, brand: 0xFF6000, kinds: ["credit_card", "savings", "student_loan"],
              products: ["credit_card": "Discover it Cash Back", "savings": "Online Savings"]),
        .init(id: "robinhood", name: "Robinhood", domain: "robinhood.com", category: .investing, brand: 0x00C805, kinds: ["brokerage"],
              products: ["brokerage": "Individual Investing"]),
        .init(id: "fidelity", name: "Fidelity", domain: "fidelity.com", category: .investing, brand: 0x368727, kinds: ["brokerage", "retirement"],
              products: ["brokerage": "Individual Brokerage", "retirement": "Roth IRA"], aliases: ["fidelity investments"]),
        .init(id: "schwab", name: "Charles Schwab", domain: "schwab.com", category: .investing, brand: 0x00A0DF, kinds: ["brokerage", "checking", "retirement"],
              products: ["brokerage": "Schwab One Brokerage", "checking": "Investor Checking", "retirement": "Roth IRA"], aliases: ["schwab"]),
        .init(id: "vanguard", name: "Vanguard", domain: "vanguard.com", category: .investing, brand: 0x96151D, kinds: ["brokerage", "retirement"],
              products: ["brokerage": "Individual Brokerage", "retirement": "Roth IRA"]),
        .init(id: "coinbase", name: "Coinbase", domain: "coinbase.com", category: .investing, brand: 0x0052FF, kinds: ["brokerage"],
              products: ["brokerage": "Crypto Portfolio"]),
        .init(id: "ally", name: "Ally", domain: "ally.com", category: .bank, brand: 0x8A3FFC, kinds: ["savings", "checking"],
              products: ["savings": "Online Savings", "checking": "Spending Account"], aliases: ["ally bank"]),
        .init(id: "sofi", name: "SoFi", domain: "sofi.com", category: .bank, brand: 0x00A2C7, kinds: ["checking", "savings", "student_loan"],
              products: ["checking": "SoFi Checking", "savings": "SoFi Savings", "student_loan": "Student Loan Refinance"]),
        .init(id: "chime", name: "Chime", domain: "chime.com", category: .bank, brand: 0x1EC677, kinds: ["checking", "savings"],
              products: ["checking": "Checking Account", "savings": "Savings Account"]),
        .init(id: "marcus", name: "Marcus by Goldman Sachs", domain: "marcus.com", category: .bank, brand: 0x1C2B39, kinds: ["savings"],
              products: ["savings": "Online Savings"], aliases: ["marcus"]),
        .init(id: "us_bank", name: "U.S. Bank", domain: "usbank.com", category: .bank, brand: 0x0C2074, kinds: ["checking", "savings", "credit_card"],
              products: ["checking": "Smartly Checking", "savings": "Standard Savings", "credit_card": "Cash+ Visa Signature"], aliases: ["us bank"]),
        .init(id: "sallie_mae", name: "Sallie Mae", domain: "salliemae.com", category: .loans, brand: 0x0F2C52, kinds: ["student_loan", "savings"],
              products: ["student_loan": "Smart Option Student Loan", "savings": "High-Yield Savings"]),
        .init(id: "venmo", name: "Venmo", domain: "venmo.com", category: .payments, brand: 0x008CFF, kinds: ["checking"],
              products: ["checking": "Venmo Balance"]),
        .init(id: "paypal", name: "PayPal", domain: "paypal.com", category: .payments, brand: 0x003087, kinds: ["checking"],
              products: ["checking": "PayPal Balance"]),
    ]

    /// Shown first in the add-account picker.
    static let popular = ["chase", "bank_of_america", "wells_fargo", "capital_one", "american_express", "citi", "robinhood", "fidelity", "schwab"]

    static func named(_ name: String) -> Institution? {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        return all.first { $0.name.lowercased() == n || $0.aliases.contains(n) }
    }
    static func id(_ id: String) -> Institution? { all.first { $0.id == id } }
}

enum AccountKind {
    static let all = ["checking", "savings", "credit_card", "brokerage", "retirement", "student_loan"]
    static func name(_ kind: String) -> String {
        ["checking": "Checking", "savings": "Savings", "brokerage": "Brokerage", "retirement": "Retirement",
         "credit_card": "Credit card", "student_loan": "Student loan"][kind] ?? kind.replacingOccurrences(of: "_", with: " ").capitalized
    }
    static func side(_ kind: String) -> Account.Side { ["credit_card", "student_loan", "mortgage", "loan"].contains(kind) ? .liability : .asset }

    enum Group: Int, CaseIterable { case cash, investments, cards, loans
        var title: String { ["Cash", "Investments", "Credit cards", "Loans"][rawValue] }
    }
    static func group(_ kind: String) -> Group {
        switch kind {
        case "checking", "savings": return .cash
        case "credit_card": return .cards
        case "student_loan", "mortgage", "loan": return .loans
        default: return .investments
        }
    }
}

/// Display details for one dataset account. The mask is a stable display label derived from the account ID,
/// not an account number from the institution.
struct AccountDisplay {
    let accountId: String
    let institutionName: String
    let kind: String
    let sourceId: String?
    init(_ a: AccountBalance) { accountId = a.accountId; institutionName = a.institution; kind = a.kind; sourceId = a.sourceId }
    init(_ a: Account) { accountId = a.accountId; institutionName = a.institution; kind = a.kind; sourceId = a.sourceId }

    var institution: Institution? { Institution.named(institutionName) }
    var title: String { institution?.product(kind) ?? "\(institutionName) \(AccountKind.name(kind))" }
    var mask: String {
        var h: UInt32 = 2_166_136_261 // FNV-1a: stable across launches, unlike Hasher
        for b in accountId.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return String(format: "%04d", Int(h % 9000) + 1000)
    }
    var subtitle: String { "\(AccountKind.name(kind)) ••\(mask)" }
    /// Added on this phone: a statement import or a SimpleFIN link. Both persist in the ledger and can be removed.
    var isImported: Bool { isLinked || sourceId?.hasPrefix("csv:") == true }
    var isLinked: Bool { sourceId?.hasPrefix("sfin:") == true }
    var originLabel: String { isLinked ? "Linked via SimpleFIN" : isImported ? "Statement imported on this iPhone" : "Sample data" }
    var color: Color { institution?.color ?? Theme.accent }
}

/// Rounded-square institution mark: the bundled logo, or a brand-coloured monogram for names Lana doesn't know.
struct InstitutionLogo: View {
    let name: String
    var size: CGFloat = 40
    private var institution: Institution? { Institution.named(name) }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
        Group {
            if let id = institution?.id, let image = LogoImages.image(id) {
                image.resizable().interpolation(.high).scaledToFill()
            } else {
                Text(String(name.prefix(1)).uppercased()).font(.system(size: size * 0.45, weight: .bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(LinearGradient(colors: [institution?.color ?? Theme.accent, (institution?.color ?? Theme.accent).opacity(0.75)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }
}

@MainActor
enum LogoImages {
    private static var cache: [String: Image] = [:]
    static func image(_ id: String) -> Image? {
        if let hit = cache[id] { return hit }
        guard let url = Bundle.module.url(forResource: id, withExtension: "png")
                ?? Bundle.module.url(forResource: id, withExtension: "png", subdirectory: "InstitutionLogos") else { return nil }
        #if canImport(UIKit)
        guard let ui = UIImage(contentsOfFile: url.path) else { return nil }
        let image = Image(uiImage: ui)
        #else
        guard let ns = NSImage(contentsOf: url) else { return nil }
        let image = Image(nsImage: ns)
        #endif
        cache[id] = image
        return image
    }
}
