import Foundation
import CourseBoyKit

enum CourseTCXFileCoder {
    static func makeRecord(from data: Data, fallbackTitle: String, sourceFilePath: String? = nil) throws -> CourseRecord {
        let tcxCourse = try TCXCourse(data: data)
        let title = normalizedTitle(tcxCourse.courseName, fallback: fallbackTitle)
        let trackPoints = tcxCourse.trackPoints

        let course = CourseRecord(title: title, sourceFilePath: sourceFilePath)
        if let first = trackPoints.first, let last = trackPoints.last {
            course.routePoints = [
                CourseRoutePoint(lat: first.lat, lon: first.lon),
                CourseRoutePoint(lat: last.lat, lon: last.lon),
            ]
            course.trackSegments = [trackPoints.map(TrackPointCodable.init)]
        }

        course.cuePoints = tcxCourse.coursePoints.map { point in
            let nearestIndex = Geo.nearestIndex(trackPoints, lat: point.lat, lon: point.lon)
            let distanceMeters = nearestIndex.map { trackPoints[$0].cumKm * 1000 } ?? 0
            return CourseCuePoint(
                lat: point.lat,
                lon: point.lon,
                name: point.name,
                pointType: point.pointType,
                notes: point.notes ?? "",
                distanceMeters: distanceMeters
            )
        }
        .sorted { $0.distanceMeters < $1.distanceMeters }

        return course
    }

    static func makeTCXData(from course: CourseRecord) throws -> Data {
        try makeTCXData(title: course.title, trackPoints: course.allTrackPoints, cuePoints: course.cuePoints)
    }

    static func makeTCXData(title: String, trackPoints: [TrackPoint], cuePoints: [CourseCuePoint]) throws -> Data {
        let specs = cuePoints.compactMap { cue -> TCXCourse.CuePointSpec? in
            guard let idx = Geo.nearestIndex(trackPoints, lat: cue.lat, lon: cue.lon) else { return nil }
            let point = trackPoints[idx]
            return TCXCourse.CuePointSpec(
                idx: idx,
                time: point.time,
                lat: cue.lat,
                lon: cue.lon,
                ele: point.ele,
                name: cue.name,
                pointType: cue.pointType,
                notes: cue.notes
            )
        }

        return try TCXCourse.buildCourseData(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            trackPoints: trackPoints,
            cuePoints: specs
        ).data
    }

    private static func normalizedTitle(_ title: String?, fallback: String) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        let fallbackTrimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackTrimmed.isEmpty ? "Course" : fallbackTrimmed
    }
}
