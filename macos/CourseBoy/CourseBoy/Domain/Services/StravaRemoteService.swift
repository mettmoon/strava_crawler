import Foundation
import CourseBoyKit

protocol StravaRemoteService: Sendable {
    func downloadTCX(routeID: String, credentials: Credentials) async throws -> Data
    func fetchSegmentIDs(routeID: String, credentials: Credentials) async throws -> [String]
    func fetchSegment(id: String, credentials: Credentials) async throws -> SegmentInfo
    func fetchMyRoutes(after: String, pageSize: Int, credentials: Credentials) async throws -> MyRoutesPage
    func fetchCSRFToken(credentials: Credentials) async throws -> String
}
