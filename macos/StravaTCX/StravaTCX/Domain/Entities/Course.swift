import Foundation
import StravaTCXKit

struct Course: Sendable, Identifiable {
    let id: UUID
    var title: String
    var createdAt: Date
    var routePoints: [CourseRoutePoint]
    var trackSegments: [[TrackPointCodable]]
    var cuePoints: [CourseCuePoint]
    var sourceRouteID: String?
}
