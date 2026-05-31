import Foundation
import Security

/// 앱 전역 설정. Strava 쿠키는 Keychain 에 저장.
enum AppSettings {
    private static let cookieAccount = "strava_session"

    static var cookie: String {
        get { Keychain.read(cookieAccount) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { Keychain.delete(cookieAccount) }
            else { Keychain.write(cookieAccount, trimmed) }
        }
    }
}

/// 최소 Keychain 래퍼 (generic password, data-protection keychain).
enum Keychain {
    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.peter.StravaTCX",
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    static func read(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    static func write(_ account: String, _ value: String) {
        let data = Data(value.utf8)
        let query = baseQuery(account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }
}
