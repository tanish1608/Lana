import Foundation
import Security
import LocalAuthentication
import CryptoKit

public struct VaultKey: Sendable, Equatable {
    public let userID: String
    public let name: String
    public init(userID: String, name: String) { self.userID = userID; self.name = name }
}

public protocol SecretStoring: Sendable {
    func store(_ secret: Data, for key: VaultKey) async throws
    func read(_ key: VaultKey, reason: String) async throws -> Data
    func remove(_ key: VaultKey) async throws
}

public struct VaultError: Error, LocalizedError, Sendable {
    public let status: OSStatus
    public var errorDescription: String? {
        switch status {
        case errSecItemNotFound: "No credential is stored for this service."
        case errSecUserCanceled: "Credential access was cancelled."
        case errSecAuthFailed, errSecInteractionNotAllowed: "Unlock the device and complete authentication to access the credential."
        default: "Secure credential storage failed (\(status))."
        }
    }
}

/// Device-bound, passcode-required Keychain storage. No plaintext-file fallback,
/// iCloud synchronization, secret logging, or model access.
public actor KeychainVault: SecretStoring {
    private let service: String
    public init(service: String) throws {
        guard !service.isEmpty else { throw FinanceAIError.invalidConfiguration }
        self.service = service
    }
    public func store(_ secret: Data, for key: VaultKey) async throws {
        guard !secret.isEmpty else { throw FinanceAIError.invalidSecret }
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil,
                    kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, .userPresence, &error) else {
            throw FinanceAIError.unavailable("Passcode-protected Keychain storage is unavailable.")
        }
        var query = try base(key)
        query[kSecAttrAccessControl as String] = access
        query[kSecValueData as String] = secret
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            var match = try base(key)
            let context = LAContext()
            context.localizedReason = "Update this service credential"
            match[kSecUseAuthenticationContext as String] = context
            let update = SecItemUpdate(match as CFDictionary,
                    [kSecValueData as String: secret, kSecAttrAccessControl as String: access] as CFDictionary)
            guard update == errSecSuccess else { throw VaultError(status: update) }
        } else if status != errSecSuccess { throw VaultError(status: status) }
    }
    public func read(_ key: VaultKey, reason: String) async throws -> Data {
        guard !reason.isEmpty else { throw FinanceAIError.invalidConfiguration }
        var query = try base(key)
        let context = LAContext()
        context.localizedReason = reason
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw VaultError(status: status) }
        guard let data = result as? Data else { throw FinanceAIError.invalidSecret }
        return data
    }
    public func remove(_ key: VaultKey) async throws {
        let status = SecItemDelete(try base(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError(status: status) }
    }
    private func base(_ key: VaultKey) throws -> [String: Any] {
        guard !key.userID.isEmpty, !key.name.isEmpty else { throw FinanceAIError.invalidConfiguration }
        // Length-prefixed fields avoid delimiter collisions; opaque Keychain account label.
        let label = "\(key.userID.utf8.count):\(key.userID)\(key.name.utf8.count):\(key.name)"
        let digest = SHA256.hash(data: Data(label.utf8)).map { String(format: "%02x", $0) }.joined()
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: digest,
                kSecAttrSynchronizable as String: false]
    }
}

public struct DeviceOwnerAuthenticator: ActionAuthenticating {
    public init() {}
    public func authenticate(reason: String) async throws {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw FinanceAIError.unavailable("Set a device passcode to authorize actions.")
        }
        do {
            guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else {
                throw FinanceAIError.authenticationFailed
            }
        } catch { throw FinanceAIError.authenticationFailed }
    }
}
