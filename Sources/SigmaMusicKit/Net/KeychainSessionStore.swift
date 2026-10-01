import Foundation
#if canImport(Security)
import Security

/// Keeps the small files in the Keychain. Unlike the app's container, the Keychain survives deleting and
/// reinstalling the app, which matters when a free developer account makes you reinstall every seven days.
///
/// Reads fall back to `fallback` (files written by an earlier version); a write that the Keychain refuses goes
/// to `fallback` too, so a login is never lost to a Keychain problem. Items are readable after the first unlock,
/// so playback with the screen off can still sign requests.
public struct KeychainSessionStore: SessionStore {
    public let service: String
    public let fallback: (any SessionStore)?

    public init(service: String, fallback: (any SessionStore)? = nil) {
        self.service = service
        self.fallback = fallback
    }

    private func query(_ name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: name,
        ]
    }

    public func read(_ name: String) -> Data? {
        var request = query(name)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        if SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            return data
        }
        return fallback?.read(name)
    }

    public func write(_ name: String, _ data: Data) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        var status = SecItemUpdate(query(name) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query(name).merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        if status == errSecSuccess {
            fallback?.remove(name)  // the Keychain copy is the one to read from now
            return
        }
        if let fallback {
            try fallback.write(name, data)
            return
        }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }

    public func remove(_ name: String) {
        SecItemDelete(query(name) as CFDictionary)
        fallback?.remove(name)
    }
}
#endif
