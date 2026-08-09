import Foundation
import Security

public enum KeychainError: Error, CustomStringConvertible, Equatable {
    /// A `SecItem*` call failed with something other than "not found".
    case operationFailed(operation: String, status: OSStatus)
    /// An item came back that is not the UTF-8 string we stored.
    case malformedItem(account: String)

    public var description: String {
        switch self {
        case .operationFailed(let operation, let status):
            let detail = SecCopyErrorMessageString(status, nil) as String?
                ?? "OSStatus \(status)"
            if status == errSecUserCanceled || status == errSecAuthFailed {
                return """
                    Keychain access was denied while trying to \(operation). \(detail) \
                    If this keeps coming back after every build, the app is being signed ad \
                    hoc — its identity changes each time, so the keychain treats it as a \
                    different app. See CODESIGN_IDENTITY in the Makefile.
                    """
            }
            return "Could not \(operation) in the keychain: \(detail)"
        case .malformedItem(let account):
            return "The keychain item for \(account) is not readable text. Save the value again."
        }
    }
}

/// Generic-password storage in the user's login keychain.
///
/// Items are keyed by `(service, account)`. Nothing is cached in memory beyond
/// the caller's own variable, so removing an item really does remove it.
public struct Keychain: Sendable {
    /// The bundle identifier the Makefile signs the app with. Used verbatim
    /// under `swift run` too, so a key saved in either place is found in both.
    public static let defaultService = "com.buckleypaul.zmkonfig"

    public let service: String

    public init(service: String = Keychain.defaultService) {
        self.service = service
    }

    /// The stored value, or nil if there is no item for `account`.
    public func string(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
                throw KeychainError.malformedItem(account: account)
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.operationFailed(operation: "read \(account)", status: status)
        }
    }

    /// Writes `value`, replacing any existing item for `account`.
    public func set(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let query = baseQuery(account: account)

        let update = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw KeychainError.operationFailed(operation: "update \(account)", status: update)
        }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let added = SecItemAdd(insert as CFDictionary, nil)
        guard added == errSecSuccess else {
            throw KeychainError.operationFailed(operation: "save \(account)", status: added)
        }
    }

    /// Removes the item. Removing one that is not there is not an error.
    public func remove(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.operationFailed(operation: "delete \(account)", status: status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
