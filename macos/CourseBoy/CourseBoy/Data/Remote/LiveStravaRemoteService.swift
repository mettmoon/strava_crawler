import Foundation
import CourseBoyKit

struct LiveStravaRemoteService: StravaRemoteService {
    private func client(_ credentials: Credentials) -> StravaClient {
        let trimmed = credentials.cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookies = trimmed.isEmpty ? [:] : ["_strava4_session": trimmed]
        let token = credentials.csrfToken
        return StravaClient(cookies: cookies, csrfToken: token.isEmpty ? nil : token)
    }

    func downloadTCX(routeID: String, credentials: Credentials) async throws -> Data {
        try await client(credentials).downloadRouteTCX(routeID: routeID)
    }

    func fetchSegmentIDs(routeID: String, credentials: Credentials) async throws -> [String] {
        try await client(credentials).fetchSegmentIDs(routeID: routeID)
    }

    func fetchSegment(id: String, credentials: Credentials) async throws -> SegmentInfo {
        try await client(credentials).fetchSegment(segmentID: id)
    }

    func fetchMyRoutes(after: String, pageSize: Int, credentials: Credentials) async throws -> MyRoutesPage {
        let c = client(credentials)
        let csrfToken = credentials.csrfToken.isEmpty
            ? (try await c.fetchCSRFToken())
            : credentials.csrfToken
        return try await c.fetchMyRoutes(after: after, pageSize: pageSize, csrfToken: csrfToken)
    }

    func fetchCSRFToken(credentials: Credentials) async throws -> String {
        try await client(credentials).fetchCSRFToken()
    }
}
