import Foundation
import StravaTCXKit

struct MakeCourseFromRouteUseCase: Sendable {
    let routeRepository: any RouteRepository
    let courseRepository: any CourseRepository

    func execute(routeID: String) async throws -> Course {
        guard let route = try await routeRepository.fetch(id: routeID) else {
            throw UseCaseError.notFound
        }
        let tcxCourse = try TCXCourse(data: route.tcxData)
        let trackPoints = tcxCourse.trackPoints

        var routePoints: [CourseRoutePoint] = []
        var trackSegments: [[TrackPointCodable]] = []

        if !trackPoints.isEmpty {
            let first = trackPoints.first!
            let last = trackPoints.last!
            routePoints = [
                CourseRoutePoint(lat: first.lat, lon: first.lon),
                CourseRoutePoint(lat: last.lat, lon: last.lon),
            ]
            let segment = trackPoints.map(TrackPointCodable.init)
            trackSegments = [segment]
        }

        let course = Course(
            id: UUID(),
            title: route.title,
            createdAt: Date(),
            routePoints: routePoints,
            trackSegments: trackSegments,
            cuePoints: [],
            sourceRouteID: routeID
        )
        try await courseRepository.save(course)
        return course
    }
}
