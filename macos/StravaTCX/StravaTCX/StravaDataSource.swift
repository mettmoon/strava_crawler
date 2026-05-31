import Foundation
import StravaTCXKit

/// 앱이 데이터를 얻는 인터페이스. 세그먼트는 ID 목록 → 개별 조회로 나눠
/// ImportCoordinator 가 진행률을 보고할 수 있게 한다.
protocol StravaDataSource: Sendable {
    func downloadTCX(routeID: String, cookie: String) async throws -> Data
    func fetchSegmentIDs(routeID: String, cookie: String) async throws -> [String]
    func fetchSegment(id: String, cookie: String) async throws -> SegmentInfo
}

/// 실 Strava 스크래핑 (StravaClient 래퍼).
struct LiveDataSource: StravaDataSource {
    private func client(_ cookie: String) -> StravaClient {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookies = trimmed.isEmpty ? [:] : ["_strava4_session": trimmed]
        let token = AppSettings.csrfToken
        return StravaClient(cookies: cookies, csrfToken: token.isEmpty ? nil : token)
    }

    func downloadTCX(routeID: String, cookie: String) async throws -> Data {
        try await client(cookie).downloadRouteTCX(routeID: routeID)
    }

    func fetchSegmentIDs(routeID: String, cookie: String) async throws -> [String] {
        try await client(cookie).fetchSegmentIDs(routeID: routeID)
    }

    func fetchSegment(id: String, cookie: String) async throws -> SegmentInfo {
        try await client(cookie).fetchSegment(segmentID: id)
    }
}
