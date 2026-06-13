import Foundation
import CourseBoyKit

struct ReloadSegmentUseCase: Sendable {
    let segmentRepository: any SegmentRepository
    let routeRepository: any RouteRepository
    let remoteService: any StravaRemoteService
    let credentialsProvider: @Sendable () -> Credentials

    func execute(segmentID: String) async throws {
        try await segmentRepository.invalidate(id: segmentID)
        let creds = credentialsProvider()
        var info = try await remoteService.fetchSegment(id: segmentID, credentials: creds)
        try await segmentRepository.save(info)

        // 해당 세그먼트를 포함하는 모든 Route 업데이트
        var routes = try await routeRepository.fetchAll()
        for i in routes.indices {
            guard let idx = routes[i].segments.firstIndex(where: { $0.segmentID == segmentID }) else { continue }
            let order = routes[i].segments[idx].order
            info.order = order
            routes[i].segments[idx] = info
            try await routeRepository.save(routes[i])
        }
    }
}
