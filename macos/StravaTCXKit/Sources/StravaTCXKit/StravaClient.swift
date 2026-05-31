import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum StravaError: Error, LocalizedError {
    case http(Int, url: String)
    case notAuthenticated
    case notTCX
    case noSegmentJSON
    case noSegmentIDs
    case noCSRF

    public var errorDescription: String? {
        switch self {
        case let .http(code, url): return "HTTP \(code) (URL=\(url))"
        case .notAuthenticated:
            return "세션이 만료되었습니다. Strava 에 다시 로그인하세요."
        case .notTCX: return "TCX 응답이 아닙니다. 쿠키 만료 또는 라우트가 비공개일 수 있습니다."
        case .noSegmentJSON:
            return "segment JSON(__NEXT_DATA__)을 찾지 못했습니다. 쿠키 만료/비공개 또는 페이지 레이아웃 변경일 수 있습니다."
        case .noSegmentIDs: return "segment ID 를 추출하지 못했습니다."
        case .noCSRF: return "CSRF 토큰을 찾지 못했습니다. 로그인 상태를 확인하세요."
        }
    }
}

/// Strava 스크래핑 클라이언트. _strava4_session 쿠키로 인증.
public struct StravaClient: Sendable {
    public var cookies: [String: String]
    /// 로그인 시 수확한 X-Csrf-Token 값(있으면 모든 요청에 포함).
    public var csrfToken: String?
    public var session: URLSession

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    public init(cookies: [String: String], csrfToken: String? = nil, session: URLSession = .shared) {
        self.cookies = cookies
        self.csrfToken = csrfToken
        self.session = session
    }

    private func makeRequest(_ url: URL, accept: String, referer: String? = nil) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        req.setValue("ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7", forHTTPHeaderField: "Accept-Language")
        if let referer { req.setValue(referer, forHTTPHeaderField: "Referer") }
        if !cookies.isEmpty {
            let cookieHeader = cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        if let csrfToken, !csrfToken.isEmpty {
            req.setValue(csrfToken, forHTTPHeaderField: "X-Csrf-Token")
        }
        return req
    }

    private func statusCode(_ response: URLResponse) -> Int {
        (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// 세션 만료 시 Strava 는 보호 페이지를 로그인 페이지로 302 시킨다.
    /// URLSession 이 리다이렉트를 자동 추종하므로 최종 URL 이 로그인/세션 페이지면
    /// 200 이라도 인증 실패로 간주한다.
    private func isLoginRedirect(_ response: URLResponse) -> Bool {
        guard let url = response.url else { return false }
        let path = url.path
        return path.hasPrefix("/login") || path.hasPrefix("/session") || path.hasPrefix("/onboarding")
    }

    /// 응답이 200 인지 검증. 로그인 리다이렉트 또는 401/403 은 `notAuthenticated`,
    /// 그 외 비-200 은 `http` 로 던진다.
    private func validate(_ response: URLResponse, url: URL) throws {
        if isLoginRedirect(response) { throw StravaError.notAuthenticated }
        let code = statusCode(response)
        // 401/403: 미인증, 419: CSRF(authenticity token) 만료.
        if code == 401 || code == 403 || code == 419 { throw StravaError.notAuthenticated }
        guard code == 200 else { throw StravaError.http(code, url: url.absoluteString) }
    }

    // MARK: - 1) 라우트 TCX 다운로드

    public func downloadRouteTCX(routeID: String) async throws -> Data {
        let url = URL(string: "https://www.strava.com/routes/\(routeID)/export_tcx")!
        let req = makeRequest(url, accept: "application/vnd.garmin.tcx+xml, application/xml, */*",
                              referer: "https://www.strava.com/routes/\(routeID)")
        let (data, response) = try await session.data(for: req)
        try validate(response, url: url)
        let head = String(data: data.prefix(4096), encoding: .utf8) ?? ""
        if !head.contains("TrainingCenterDatabase") {
            let full = String(data: data, encoding: .utf8) ?? ""
            if !full.contains("TrainingCenterDatabase") { throw StravaError.notTCX }
        }
        return data
    }

    // MARK: - 2) 라우트 페이지 → segment ID 순서대로

    public func fetchSegmentIDs(routeID: String) async throws -> [String] {
        let url = URL(string: "https://www.strava.com/routes/\(routeID)")!
        let req = makeRequest(url, accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        let (data, response) = try await session.data(for: req)
        try validate(response, url: url)
        let html = String(data: data, encoding: .utf8) ?? ""
        let ids = Self.extractSegmentIDs(html: html)
        if ids.isEmpty { throw StravaError.noSegmentIDs }
        return ids
    }

    /// route HTML 에서 순서대로 segment id 추출 (Python extract_segment_ids 와 동일 우선순위).
    static func extractSegmentIDs(html: String) -> [String] {
        var seen = Set<String>()
        var ids: [String] = []
        func push(_ s: String) {
            guard s.allSatisfy(\.isNumber), !s.isEmpty, !seen.contains(s) else { return }
            seen.insert(s); ids.append(s)
        }
        for m in matches(html, #"data-segment-id=[\"'](\d+)[\"']"#, group: 1) { push(m) }
        for m in matches(html, #"href=\"/segments/(\d+)\""#, group: 1) { push(m) }
        if let block = firstMatch(html, #"\"segments\"\s*:\s*\[(.*?)\]"#, group: 1, dotMatchesAll: true) {
            for m in matches(block, #"\"(?:segment_id|id)\"\s*:\s*(\d+)"#, group: 1) { push(m) }
        }
        if ids.isEmpty {
            for m in matches(html, #"segment[_-]?id[\"']?\s*[:=]\s*[\"']?(\d+)"#, group: 1, caseInsensitive: true) {
                push(m)
            }
        }
        return ids
    }

    // MARK: - 3) segment 상세

    public func fetchSegment(segmentID: String) async throws -> SegmentInfo {
        let url = URL(string: "https://www.strava.com/segments/\(segmentID)")!
        let req = makeRequest(url, accept: "text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8")
        let (data, response) = try await session.data(for: req)
        try validate(response, url: url)
        let html = String(data: data, encoding: .utf8) ?? ""
        guard let jsonString = Self.extractNextDataJSON(html: html),
              let pageProps = try NextData.pageProps(from: Data(jsonString.utf8)),
              pageProps.metadata != nil else {
            throw StravaError.noSegmentJSON
        }
        return SegmentInfo.from(pageProps: pageProps, segmentID: segmentID)
    }

    /// HTML 에서 __NEXT_DATA__ 스크립트의 JSON 문자열 추출.
    static func extractNextDataJSON(html: String) -> String? {
        firstMatch(
            html,
            #"<script id=\"__NEXT_DATA__\"[^>]*>(.*?)</script>"#,
            group: 1, dotMatchesAll: true
        )
    }

    // MARK: - 내 라우트 (my-routes API)

    private var cookieHeader: String {
        cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    /// 인증된 페이지에서 csrf-token 추출.
    public func fetchCSRFToken() async throws -> String {
        let url = URL(string: "https://www.strava.com/athlete/routes")!
        let req = makeRequest(url, accept: "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8")
        let (data, response) = try await session.data(for: req)
        try validate(response, url: url)
        let html = String(decoding: data, as: UTF8.self)
        guard let token = MyRoutesParser.extractCSRF(html: html) else { throw StravaError.noCSRF }
        return token
    }

    /// 내 라우트 한 페이지 조회. after 는 오프셋 커서("0","16",…).
    public func fetchMyRoutes(after: String, pageSize: Int, csrfToken: String) async throws -> MyRoutesPage {
        let url = URL(string: "https://www.strava.com/api/next/data/routes/my-routes")!
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(csrfToken, forHTTPHeaderField: "X-Csrf-Token")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://www.strava.com/athlete/routes", forHTTPHeaderField: "Referer")
        if !cookies.isEmpty {
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        req.httpBody = MyRoutesParser.requestBody(after: after, pageSize: pageSize)

        let (data, response) = try await session.data(for: req)
        try validate(response, url: url)
        return MyRoutesParser.parse(data, pageSize: pageSize)
    }
}

// MARK: - 정규식 헬퍼

private func regex(_ pattern: String, dotMatchesAll: Bool, caseInsensitive: Bool) -> NSRegularExpression? {
    var options: NSRegularExpression.Options = []
    if dotMatchesAll { options.insert(.dotMatchesLineSeparators) }
    if caseInsensitive { options.insert(.caseInsensitive) }
    return try? NSRegularExpression(pattern: pattern, options: options)
}

private func matches(
    _ s: String, _ pattern: String, group: Int,
    dotMatchesAll: Bool = false, caseInsensitive: Bool = false
) -> [String] {
    guard let re = regex(pattern, dotMatchesAll: dotMatchesAll, caseInsensitive: caseInsensitive) else { return [] }
    let range = NSRange(s.startIndex..., in: s)
    return re.matches(in: s, options: [], range: range).compactMap { m in
        guard let r = Range(m.range(at: group), in: s) else { return nil }
        return String(s[r])
    }
}

private func firstMatch(
    _ s: String, _ pattern: String, group: Int,
    dotMatchesAll: Bool = false, caseInsensitive: Bool = false
) -> String? {
    matches(s, pattern, group: group, dotMatchesAll: dotMatchesAll, caseInsensitive: caseInsensitive).first
}
