import Foundation
import StravaTCXKit

struct ComputeRouteSegmentUseCase: Sendable {
    func execute(from start: CourseRoutePoint?, to end: CourseRoutePoint) async -> [TrackPointCodable] {
        guard let start else { return [] }
        return await OSRMRouter.shared.route(from: start, to: end)
    }
}
