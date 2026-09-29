import Foundation
import Security

/// Minimal Keychain wrapper for account tokens. All secrets live in one
/// generic password item as a JSON dictionary, because macOS asks for
/// permission once per item whenever the app's signature changes (every
/// ad-hoc build or update).
enum KeychainStore {
    private static let service = "CineTray"
    private static let account = "secrets"
    /// nil until the item has been read, and after a failed read, so a later
    /// access asks again instead of overwriting secrets it could not read.
    private static var cache: [String: String]?

    static func string(for key: String) -> String? {
        secrets()?[key]
    }

    /// Passing nil or an empty string removes the value. Returns whether the
    /// Keychain was updated.
    @discardableResult
    static func set(_ value: String?, for key: String) -> Bool {
        guard var all = secrets() else { return false }
        all[key] = value?.isEmpty == false ? value : nil
        return save(all)
    }

    /// Reads a secret, migrating it out of UserDefaults if an older build
    /// stored it there.
    static func stringMigratingFromDefaults(for key: String) -> String? {
        if let existing = string(for: key) { return existing }
        guard let legacy = UserDefaults.standard.string(forKey: key), !legacy.isEmpty else {
            return nil
        }
        // Kept in UserDefaults until the Keychain has it, so a denied
        // Keychain prompt doesn't lose it; the next launch tries again.
        if set(legacy, for: key) {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return legacy
    }

    private static func secrets() -> [String: String]? {
        if let cache { return cache }
        let (data, status) = read(account: account)
        if let data {
            // An item that doesn't decode holds nothing usable; start over.
            cache = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        } else if status == errSecItemNotFound {
            cache = migrateItemPerKey()
        }
        return cache
    }

    @discardableResult
    private static func save(_ all: [String: String]) -> Bool {
        guard let data = try? JSONEncoder().encode(all) else { return false }
        cache = all
        let query = baseQuery(for: account)
        // Update in place rather than delete and add, so a failed add can't
        // lose every secret at once.
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status == errSecSuccess }
        var attributes = query
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Older builds stored one item per key. Moves them into the shared
    /// item; this asks for permission once per old item, one time only.
    private static func migrateItemPerKey() -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return [:]
        }
        var all: [String: String] = [:]
        for key in items.compactMap({ $0[kSecAttrAccount as String] as? String }) {
            if let data = read(account: key).data, let value = String(data: data, encoding: .utf8) {
                all[key] = value
            }
        }
        // Old items are removed only once their values are safely stored;
        // one that couldn't be read stays where it is.
        if save(all) {
            for key in all.keys {
                SecItemDelete(baseQuery(for: key) as CFDictionary)
            }
        }
        return all
    }

    private static func read(account: String) -> (data: Data?, status: OSStatus) {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (result as? Data, status)
    }

    private static func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
