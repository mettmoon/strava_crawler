import Foundation

enum CourseMapper {
    static func toDomain(_ record: CourseRecord) -> Course {
        Course(
            id: record.id,
            title: record.title,
            createdAt: record.createdAt,
            routePoints: record.routePoints,
            trackSegments: record.trackSegments,
            cuePoints: record.cuePoints,
            sourceRouteID: record.sourceRouteID,
            sourceFilePath: record.sourceFilePath
        )
    }

    static func apply(_ course: Course, to record: CourseRecord) {
        record.title = course.title
        record.routePoints = course.routePoints
        record.trackSegments = course.trackSegments
        record.cuePoints = course.cuePoints
        record.sourceRouteID = course.sourceRouteID
        record.sourceFilePath = course.sourceFilePath
    }

    static func toRecord(_ course: Course) -> CourseRecord {
        let record = CourseRecord(
            title: course.title,
            sourceRouteID: course.sourceRouteID,
            sourceFilePath: course.sourceFilePath
        )
        record.id = course.id
        record.createdAt = course.createdAt
        record.routePoints = course.routePoints
        record.trackSegments = course.trackSegments
        record.cuePoints = course.cuePoints
        return record
    }
}
