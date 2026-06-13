import Foundation
import CourseBoyKit

protocol SegmentRepository: Sendable {
    func fetch(id: String) async throws -> SegmentInfo?
    func fetchAll() async throws -> [SegmentInfo]
    func fetchOrDownload(id: String, credentials: Credentials) async throws -> SegmentInfo
    func save(_ segment: SegmentInfo) async throws
    func invalidate(id: String) async throws
}
