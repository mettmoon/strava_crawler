import Foundation
import Security
import os

/// 앱 전역 설정. Strava 쿠키와 CSRF 토큰은 Keychain 에 저장.
enum AppSettings {
    private static let cookieAccount = "strava_session"
    private static let csrfAccount = "strava_csrf"

    static var cookie: String {
        get { Keychain.read(cookieAccount) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { Keychain.delete(cookieAccount) }
            else { Keychain.write(cookieAccount, trimmed) }
        }
    }

    /// 로그인 시 수확한 X-Csrf-Token 값. 요청 시 쿠키와 함께 보낸다.
    static var csrfToken: String {
        get { Keychain.read(csrfAccount) ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { Keychain.delete(csrfAccount) }
            else { Keychain.write(csrfAccount, trimmed) }
        }
    }

    /// segment 정보를 연속으로 가져올 때 요청 사이의 대기 시간(초).
    /// 값이 작으면 429(요청 과다) 오류가 날 수 있어 기본 5초.
    static let defaultSegmentRequestInterval: Double = 5
    private static let segmentIntervalKey = "segmentRequestInterval"

    static var segmentRequestInterval: Double {
        get {
            (UserDefaults.standard.object(forKey: segmentIntervalKey) as? Double)
                ?? defaultSegmentRequestInterval
        }
        set { UserDefaults.standard.set(max(0, newValue), forKey: segmentIntervalKey) }
    }
}

/// 최소 Keychain 래퍼 (generic password, data-protection keychain).
enum Keychain {
    private static let currentService = "dev.peter.CourseBoy"
    private static let legacyService = "dev.peter.StravaTCX"
    private static let log = Logger(subsystem: currentService, category: "Keychain")

    private static func baseQuery(_ account: String, service: String = currentService) -> [String: Any] {
        // 레거시(파일 기반) 키체인 사용: 샌드박스 + ad-hoc 로컬 서명만으로 동작한다.
        // data protection keychain(kSecUseDataProtectionKeychain)은 application-identifier/
        // keychain-access-groups 엔타이틀먼트를 요구해 미서명 빌드에서 -34018 로 실패한다.
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func read(_ account: String) -> String? {
        if let value = read(account, service: currentService, logFailures: true) {
            return value
        }
        guard let legacyValue = read(account, service: legacyService, logFailures: false) else {
            return nil
        }
        write(account, legacyValue)
        delete(account, service: legacyService, logFailures: false)
        return legacyValue
    }

    private static func read(_ account: String, service: String, logFailures: Bool) -> String? {
        var query = baseQuery(account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound && logFailures {
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
        delete(account, service: currentService, logFailures: true)
    }

    private static func delete(_ account: String, service: String, logFailures: Bool) {
        let status = SecItemDelete(baseQuery(account, service: service) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound && logFailures {
            log.error("delete('\(account, privacy: .public)') 실패: \(message(status), privacy: .public)")
        }
    }

    /// OSStatus 를 사람이 읽을 수 있는 문자열로 (코드 포함).
    private static func message(_ status: OSStatus) -> String {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "알 수 없는 오류"
        return "\(text) (\(status))"
    }
}
