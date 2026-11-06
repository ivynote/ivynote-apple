import Foundation
import Security

/// The signed-in account: kept in the Keychain so the app opens straight into
/// it, and so it keeps working offline with the cached user.
public struct StoredAccount: Codable, Equatable, Sendable {
    public var server: ServerAddress
    public var token: String
    public var user: User

    public init(server: ServerAddress, token: String, user: User) {
        self.server = server
        self.token = token
        self.user = user
    }
}

public protocol CredentialStore: Sendable {
    func load() throws -> StoredAccount?
    func save(_ account: StoredAccount) throws
    func clear() throws
}

public struct KeychainError: Error, Equatable, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        L10n.s.keychainError(SecCopyErrorMessageString(status, nil) as String? ?? String(status))
    }
}

/// One generic-password item, readable after first unlock and never synced
/// or migrated to another device.
public struct KeychainCredentialStore: CredentialStore {
    let service: String
    let account: String

    public init(service: String = "app.ivynote", account: String = "session") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func load() throws -> StoredAccount? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        // An item from an incompatible older build is dropped, not fatal.
        return try? JSONDecoder().decode(StoredAccount.self, from: data)
    }

    public func save(_ value: StoredAccount) throws {
        let data = try JSONEncoder().encode(value)
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attrs) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// For tests and SwiftUI previews.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: StoredAccount?

    public init(_ initial: StoredAccount? = nil) { value = initial }

    public func load() throws -> StoredAccount? { lock.withLock { value } }
    public func save(_ account: StoredAccount) throws { lock.withLock { value = account } }
    public func clear() throws { lock.withLock { value = nil } }
}
