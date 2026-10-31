import Foundation
import Security

public enum KeychainError: Error, Equatable {
    case unexpectedStatus(Int32)

    /// A line for the system log that keeps the OSStatus: "KeychainError.unexpectedStatus(-25308)". Bridged to
    /// NSError this error has code 0, so the status would be lost. Any other error gives its own description.
    public static func diagnostic(_ error: Error) -> String {
        if case KeychainError.unexpectedStatus(let status) = error {
            return "KeychainError.unexpectedStatus(\(status))"
        }
        return String(describing: error)
    }
}

/// When a Keychain item can be read. Both kinds are readable after the first unlock since boot (background walks
/// need that); `ThisDeviceOnly` items are left out of backups and never restored to another device.
public enum KeychainAccessibility: Sendable {
    case afterFirstUnlock
    case afterFirstUnlockThisDeviceOnly

    var value: CFString {
        switch self {
        case .afterFirstUnlock: kSecAttrAccessibleAfterFirstUnlock
        case .afterFirstUnlockThisDeviceOnly: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }
}

/// Generic-password Keychain access keyed on service + account.
public struct KeychainStore: Sendable {
    private let service: String

    public init(service: String) {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func read(_ account: String) throws -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw KeychainError.unexpectedStatus(errSecInternalError) }
            guard let string = String(data: data, encoding: .utf8) else {
                throw KeychainError.unexpectedStatus(errSecDecode)
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Stores `value`, replacing any existing item. The update sets `accessibility` too, so an item written earlier
    /// with another accessibility takes the new one.
    public func write(_ value: String, account: String, accessibility: KeychainAccessibility = .afterFirstUnlock) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(
            baseQuery(account) as CFDictionary,
            Self.updateAttributes(data: data, accessibility: accessibility) as CFDictionary
        )
        switch update {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            let add = addQuery(account, data: data, accessibility: accessibility)
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        default:
            throw KeychainError.unexpectedStatus(update)
        }
    }

    /// What `write` changes on an existing item: the data and the accessibility. Internal for tests: the macOS
    /// file-based keychain `swift test` uses does not keep `kSecAttrAccessible`, so it cannot be read back there.
    static func updateAttributes(data: Data, accessibility: KeychainAccessibility) -> [String: Any] {
        [kSecValueData as String: data, kSecAttrAccessible as String: accessibility.value]
    }

    /// What `write` adds when there is no item yet. Internal for tests, as `updateAttributes`.
    func addQuery(_ account: String, data: Data, accessibility: KeychainAccessibility) -> [String: Any] {
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = accessibility.value
        return add
    }

    public func delete(_ account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
