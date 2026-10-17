import Foundation
import LocalAuthentication
import Security

/// Keychain boundary for saved-host passwords, replaceable in tests. Values are
/// raw bytes so callers can zero their copies; they are never logged or persisted.
public protocol HostSecretStore: Sendable {
    /// Adds or replaces the password for `hostID`.
    func store(_ password: Data, hostID: UUID) throws
    func read(hostID: UUID) throws -> Data?
    func remove(hostID: UUID)
}

public enum HostSecretError: Error, Equatable, Sendable { case unavailable(OSStatus) }

/// Generic-password items in the login Keychain, one per host, readable only on this device.
public struct KeychainHostSecretStore: HostSecretStore {
    public static let service = "Trellis SSH Host"
    public init() {}

    private func query(_ hostID: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service, kSecAttrAccount as String: hostID.uuidString]
    }

    public func store(_ password: Data, hostID: UUID) throws {
        let status = SecItemUpdate(query(hostID) as CFDictionary, [kSecValueData as String: password] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw HostSecretError.unavailable(status) }
        var item = query(hostID)
        item[kSecValueData as String] = password
        item[kSecAttrLabel as String] = "Trellis SSH host password"
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else { throw HostSecretError.unavailable(added) }
    }

    public func read(hostID: UUID) throws -> Data? {
        var item = query(hostID)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw HostSecretError.unavailable(status) }
        return data
    }

    public func remove(hostID: UUID) { SecItemDelete(query(hostID) as CFDictionary) }
}

/// Default for libraries built without a Keychain (tests, previews): saving fails, nothing is read.
public struct UnavailableHostSecretStore: HostSecretStore {
    public init() {}
    public func store(_ password: Data, hostID: UUID) throws { throw HostSecretError.unavailable(errSecNotAvailable) }
    public func read(hostID: UUID) throws -> Data? { nil }
    public func remove(hostID: UUID) {}
}

/// Asks the person at the Mac to confirm before a saved password is used (FR-H07).
public protocol UserPresenceGate: Sendable {
    func authorize(reason: String) async -> Bool
}

/// Touch ID, falling back to the Mac password. Enforced by Trellis, not by the Keychain item:
/// ad-hoc builds carry no keychain-access-group entitlement for `SecAccessControl`.
public struct LocalAuthenticationGate: UserPresenceGate {
    public init() {}
    public func authorize(reason: String) async -> Bool {
        (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
