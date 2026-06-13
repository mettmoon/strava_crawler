import Foundation
import CourseBoyKit

struct BuildCuesheetUseCase: Sendable {
    let routeRepository: any RouteRepository

    func execute(routeID: String, minCategory: String?) async throws -> Cuesheet.Result {
        guard let route = try await routeRepository.fetch(id: routeID) else {
            throw UseCaseError.notFound
        }
        let tcxCourse = try TCXCourse(data: route.tcxData)
        return Cuesheet.makeEntries(
            trackPoints: tcxCourse.trackPoints,
            segments: route.segments,
            minCategory: minCategory
        )
    }
}

enum UseCaseError: LocalizedError {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound: return "데이터를 찾을 수 없습니다."
        }
    }
}
