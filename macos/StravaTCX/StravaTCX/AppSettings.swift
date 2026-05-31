import Foundation
import Security
import os

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
    private static let log = Logger(subsystem: "dev.peter.StravaTCX", category: "Keychain")

    private static func baseQuery(_ account: String) -> [String: Any] {
        // 레거시(파일 기반) 키체인 사용: 샌드박스 + ad-hoc 로컬 서명만으로 동작한다.
        // data protection keychain(kSecUseDataProtectionKeychain)은 application-identifier/
        // keychain-access-groups 엔타이틀먼트를 요구해 미서명 빌드에서 -34018 로 실패한다.
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.peter.StravaTCX",
            kSecAttrAccount as String: account,
        ]
    }

    static func read(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                log.error("read('\(account, privacy: .public)') 실패: \(message(status), privacy: .public)")
            }
            return nil
        }
        guard let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    static func write(_ account: String, _ value: String) {
        let data = Data(value.utf8)
        let query = baseQuery(account)
        var status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        if status == errSecSuccess {
            log.info("write('\(account, privacy: .public)') 성공")
        } else {
            log.error("write('\(account, privacy: .public)') 실패: \(message(status), privacy: .public)")
        }
    }

    static func delete(_ account: String) {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            log.error("delete('\(account, privacy: .public)') 실패: \(message(status), privacy: .public)")
        }
    }

    /// OSStatus 를 사람이 읽을 수 있는 문자열로 (코드 포함).
    private static func message(_ status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "알 수 없는 오류"
        return "\(text) (\(status))"
    }
}
