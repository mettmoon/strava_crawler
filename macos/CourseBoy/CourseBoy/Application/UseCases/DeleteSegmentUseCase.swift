import Foundation

struct DeleteSegmentUseCase: Sendable {
    let routeRepository: any RouteRepository
    let segmentRepository: any SegmentRepository

    func execute(segmentID: String) async throws {
        try await segmentRepository.invalidate(id: segmentID)
        var routes = try await routeRepository.fetchAll()
        for i in routes.indices {
            let before = routes[i].segments.count
            routes[i].segments.removeAll { $0.segmentID == segmentID }
            if routes[i].segments.count != before {
                try await routeRepository.save(routes[i])
            }
        }
    }
}
