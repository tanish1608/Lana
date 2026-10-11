import Foundation
import CryptoKit

public enum TOTPAlgorithm: Sendable { case sha1, sha256, sha512 }

/// RFC 6238 code generation for a user-enrolled service. This is not a verifier
/// or a substitute for the service's server-side MFA challenge and session policy.
public struct TOTP: Sendable {
    public init() {}
    public func code(secret: Data, at date: Date = Date(), digits: Int = 6,
                     period: Int = 30, algorithm: TOTPAlgorithm = .sha1) throws -> String {
        let seconds = date.timeIntervalSince1970
        guard !secret.isEmpty, (6...8).contains(digits), period > 0,
              seconds.isFinite, seconds >= 0,
              seconds / Double(period) < Double(UInt64.max) else { throw FinanceAIError.invalidSecret }
        var counter = UInt64(seconds / Double(period)).bigEndian
        let message = withUnsafeBytes(of: &counter) { Data($0) }
        let key = SymmetricKey(data: secret)
        let bytes: [UInt8]
        switch algorithm {
        case .sha1: bytes = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: key))
        case .sha256: bytes = Array(HMAC<SHA256>.authenticationCode(for: message, using: key))
        case .sha512: bytes = Array(HMAC<SHA512>.authenticationCode(for: message, using: key))
        }
        let offset = Int(bytes.last! & 0x0f)
        let binary = (UInt32(bytes[offset] & 0x7f) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
        let modulus: UInt32 = digits == 6 ? 1_000_000 : digits == 7 ? 10_000_000 : 100_000_000
        return String(format: "%0*d", digits, binary % modulus)
    }

    public static func decodeBase32(_ string: String) throws -> Data {
        let text = string.uppercased().filter { !$0.isWhitespace }
        let unpadded = String(text.prefix { $0 != "=" })
        let padding = text.count - unpadded.count
        guard !unpadded.isEmpty, [0, 2, 4, 5, 7].contains(unpadded.count % 8),
              text.dropFirst(unpadded.count).allSatisfy({ $0 == "=" }),
              padding == 0 || (text.count % 8 == 0 && padding == (8 - unpadded.count % 8) % 8) else {
            throw FinanceAIError.invalidSecret
        }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var buffer: UInt32 = 0
        var bits = 0
        var output = Data()
        for character in unpadded {
            guard let value = alphabet.firstIndex(of: character) else { throw FinanceAIError.invalidSecret }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> bits) & 0xff))
                buffer &= (1 << bits) - 1
            }
        }
        guard buffer == 0 else { throw FinanceAIError.invalidSecret }
        return output
    }
}

public struct VaultTOTPService: Sendable {
    private let vault: any SecretStoring
    public init(vault: any SecretStoring) { self.vault = vault }
    /// Binary secret, enrolled by explicit user action; never obtained through an LLM tool.
    public func enroll(base32Secret: String, for key: VaultKey) async throws {
        try await vault.store(TOTP.decodeBase32(base32Secret), for: key)
    }
    public func code(for key: VaultKey, at date: Date = Date(), digits: Int = 6,
                     period: Int = 30, algorithm: TOTPAlgorithm = .sha1) async throws -> String {
        let secret = try await vault.read(key, reason: "Generate a verification code for this service")
        return try TOTP().code(secret: secret, at: date, digits: digits, period: period, algorithm: algorithm)
    }
}
