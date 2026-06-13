import Foundation
import CourseBoyKit

struct ExportTCXUseCase: Sendable {
    let routeRepository: any RouteRepository

    struct Result: Sendable {
        var prefix: String
        var cuedData: Data
        var rwgpsData: Data
    }

    func execute(routeID: String, minCategory: String?) async throws -> Result {
        guard let route = try await routeRepository.fetch(id: routeID) else {
            throw UseCaseError.notFound
        }
        let tcxCourse = try TCXCourse(data: route.tcxData)
        let entries = Cuesheet.makeEntries(
            trackPoints: tcxCourse.trackPoints,
            segments: route.segments,
            minCategory: minCategory
        ).entries

        let (cuedData, _) = try tcxCourse.build(entries: entries, forRWGPS: false)
        let (rwgpsData, _) = try tcxCourse.build(entries: entries, forRWGPS: true)

        return Result(prefix: route.fileNamePrefix, cuedData: cuedData, rwgpsData: rwgpsData)
    }
}
