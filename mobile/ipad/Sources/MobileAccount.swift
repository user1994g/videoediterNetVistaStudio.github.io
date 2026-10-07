import Foundation
import Security

// Reuse the desktop authentication service. The iOS adapter uses its own Keychain
// namespace, never asks for a Mac Keychain prompt, and refuses anonymous users.
struct MobileSessionStore: StudioSessionStore {
    private let savedFlag = "netvista.mobile.has-saved-session"
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.netvistastudio.mobile.account",
        kSecAttrAccount as String: "session"] }
    func load() throws -> Data? {
        // First launch must not touch credential storage before the first login.
        guard UserDefaults.standard.bool(forKey: savedFlag) else { return nil }
        var request = query; request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return value as? Data
    }
    func save(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        let status = update == errSecItemNotFound ? SecItemAdd(query.merging(attributes) { _, b in b } as CFDictionary, nil) : update
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        UserDefaults.standard.set(true, forKey: savedFlag)
    }
    func clear() throws {
        guard UserDefaults.standard.bool(forKey: savedFlag) else { return }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        UserDefaults.standard.removeObject(forKey: savedFlag)
    }
}

enum MobileAccount {
    static func checkedResponse(_ result: Result<Data, Error>) -> Result<Data, Error> {
        if case .success(let data) = result {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let user = json?["user"] as? [String: Any] ?? json
            if user?["is_anonymous"] as? Bool == true {
                return .failure(StudioAuthFailure(status: 403, code: "anonymous_not_allowed"))
            }
        }
        return result
    }
    static func transport(_ request: URLRequest, completion: @escaping StudioAccount.Reply) {
        StudioAccount.send(request) { result in
            completion(checkedResponse(result))
        }
    }
}
