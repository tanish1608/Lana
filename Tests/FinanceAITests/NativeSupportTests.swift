import Foundation
import Testing
@testable import FinanceAI

private struct UnknownRouter: IntentRouting {
    func route(_ text: String) async throws -> RoutedRequest {
        .init(request: .init(intent: .unknown), source: .deterministicFallback)
    }
}
private actor SpyCloud: IntentRouting {
    private var calls = 0
    func route(_ text: String) async throws -> RoutedRequest {
        calls += 1
        return .init(request: .init(intent: .forecast), source: .cloudRelay)
    }
    func count() -> Int { calls }
}
@Test func cloudNeedsExplicitPolicy() async throws {
    let cloud = SpyCloud()
    let router = HybridRouter(local: UnknownRouter(), cloud: cloud)
    #expect(try await router.route("help").source == .deterministicFallback)
    #expect(await cloud.count() == 0)
    let optedIn = HybridRouter(local: UnknownRouter(), cloud: cloud, policy: .allowCloudForUnrecognizedRequests)
    #expect(try await optedIn.route("help").source == .cloudRelay)
    #expect(await cloud.count() == 1)
}
@Test func recognizedRequestsStayLocalEvenWhenCloudAllowed() async throws {
    let cloud = SpyCloud()
    let router = HybridRouter(local: RuleRouter(), cloud: cloud, policy: .allowCloudForUnrecognizedRequests)
    #expect(try await router.route("net worth").source == .deterministicFallback)
    #expect(await cloud.count() == 0)
}
@Test func relayRequiresHTTPS() throws {
    #expect(throws: FinanceAIError.invalidConfiguration) {
        try CloudRelayRouter(endpoint: URL(string: "http://example.com/route")!, token: { "token" })
    }
}
@Test func receiptRejectsFieldsMissingFromOCR() {
    let source = "LOCAL MARKET\nMilk 3.49\nTOTAL 3.49"
    #expect(ReceiptDraftBuilder.fieldsAppearInSource(merchant: "LOCAL MARKET", total: "3.49",
                items: [.init(name: "Milk", amountText: "3.49")], source: source))
    #expect(!ReceiptDraftBuilder.fieldsAppearInSource(merchant: "LOCAL MARKET", total: "1.99",
                items: [.init(name: "Milk", amountText: "1.99")], source: source))
    #expect(!ReceiptDraftBuilder.fieldsAppearInSource(merchant: "Invented Store", total: nil, items: [], source: source))
}

// Independent expected values from RFC 6238 Appendix B, all algorithms/timestamps.
private struct TOTPVector: Sendable {
    let seconds: Double
    let sha1: String
    let sha256: String
    let sha512: String
}
private let vectors: [TOTPVector] = [
    .init(seconds: 59, sha1: "94287082", sha256: "46119246", sha512: "90693936"),
    .init(seconds: 1111111109, sha1: "07081804", sha256: "68084774", sha512: "25091201"),
    .init(seconds: 1111111111, sha1: "14050471", sha256: "67062674", sha512: "99943326"),
    .init(seconds: 1234567890, sha1: "89005924", sha256: "91819424", sha512: "93441116"),
    .init(seconds: 2000000000, sha1: "69279037", sha256: "90698825", sha512: "38618901"),
    .init(seconds: 20000000000, sha1: "65353130", sha256: "77737706", sha512: "47863826")
]
@Test(arguments: vectors) private func totpMatchesRFC6238(vector: TOTPVector) throws {
    let date = Date(timeIntervalSince1970: vector.seconds)
    let seed = "12345678901234567890"
    #expect(try TOTP().code(secret: Data(seed.utf8), at: date, digits: 8, algorithm: .sha1) == vector.sha1)
    #expect(try TOTP().code(secret: Data((seed + "123456789012").utf8), at: date, digits: 8, algorithm: .sha256) == vector.sha256)
    #expect(try TOTP().code(secret: Data((seed + seed + seed + "1234").utf8), at: date, digits: 8, algorithm: .sha512) == vector.sha512)
}
@Test func base32AndInvalidTOTPSettings() throws {
    #expect(try TOTP.decodeBase32("MZXW6===") == Data("foo".utf8))
    #expect(try TOTP.decodeBase32("mzxw6") == Data("foo".utf8))
    #expect(throws: FinanceAIError.invalidSecret) { try TOTP.decodeBase32("MZ=INVALID") }
    #expect(throws: FinanceAIError.invalidSecret) { try TOTP.decodeBase32("MZ") }
    #expect(throws: FinanceAIError.invalidSecret) { try TOTP().code(secret: Data(), at: Date()) }
    #expect(throws: FinanceAIError.invalidSecret) { try TOTP().code(secret: Data([1]), digits: 2) }
    #expect(throws: FinanceAIError.invalidSecret) { try TOTP().code(secret: Data([1]), period: 0) }
    #expect(throws: FinanceAIError.invalidSecret) { try TOTP().code(secret: Data([1]), at: Date(timeIntervalSince1970: -1)) }
}
