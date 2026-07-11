import Foundation
import CourseBoyKit

enum CourseTCXFileCoder {
    static func makeRecord(from data: Data, fallbackTitle: String, sourceFilePath: String? = nil) throws -> CourseRecord {
        let tcxCourse = try TCXCourse(data: data)
        let title = normalizedTitle(tcxCourse.courseName, fallback: fallbackTitle)
        let course = CourseRecord(title: title, sourceFilePath: sourceFilePath)
        course.sections = tcxCourse.trackPointSections.compactMap { points in
            guard let first = points.first, let last = points.last else { return nil }
            return CourseSection(
                routePoints: [
                    CourseRoutePoint(lat: first.lat, lon: first.lon),
                    CourseRoutePoint(lat: last.lat, lon: last.lon),
                ],
                legs: [CourseLeg(kind: .routed, trackPoints: points.map(TrackPointCodable.init))]
            )
        }
        if course.sections.isEmpty { course.sections = [CourseSection()] }

        for point in tcxCourse.coursePoints {
            guard let match = nearestSectionMatch(
                in: tcxCourse.trackPointSections, lat: point.lat, lon: point.lon
            ) else { continue }
            course.sections[match.sectionIndex].cuePoints.append(CourseCuePoint(
                lat: point.lat,
                lon: point.lon,
                name: point.name,
                pointType: point.pointType,
                notes: point.notes ?? "",
                distanceMeters: match.point.cumKm * 1000
            ))
        }
        for index in course.sections.indices {
            course.sections[index].cuePoints.sort { $0.distanceMeters < $1.distanceMeters }
        }

        return course
    }

    static func makeTCXData(from course: CourseRecord) throws -> Data {
        try makeTCXData(
            title: course.title,
            tracks: adjustedTracks(course.sectionTracks),
            cuePoints: course.cuePoints
        )
    }

    static func makeTCXData(title: String, trackPoints: [TrackPoint], cuePoints: [CourseCuePoint]) throws -> Data {
        try makeTCXData(title: title, tracks: [trackPoints], cuePoints: cuePoints)
    }

    static func makeTCXData(
        title: String,
        tracks: [[TrackPoint]],
        cuePoints: [CourseCuePoint]
    ) throws -> Data {
        let trackPoints = tracks.flatMap { $0 }
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
            tracks: tracks,
            cuePoints: specs
        ).data
    }

    private static func adjustedTracks(_ tracks: [CourseSectionTrack]) -> [[TrackPoint]] {
        tracks.map { track in
            track.points.map { point in
                TrackPoint(
                    lat: point.lat, lon: point.lon, ele: point.ele, time: point.time,
                    cumKm: track.courseStartKm + point.cumKm
                )
            }
        }
    }

    private static func nearestSectionMatch(
        in sections: [[TrackPoint]],
        lat: Double,
        lon: Double
    ) -> (sectionIndex: Int, point: TrackPoint)? {
        var best: (sectionIndex: Int, point: TrackPoint)?
        var bestDistance = Double.infinity
        for (sectionIndex, points) in sections.enumerated() {
            guard let pointIndex = Geo.nearestIndex(points, lat: lat, lon: lon) else { continue }
            let point = points[pointIndex]
            let distance = Geo.haversineKm(lat, lon, point.lat, point.lon)
            if distance < bestDistance {
                bestDistance = distance
                best = (sectionIndex, point)
            }
        }
        return best
    }

    private static func normalizedTitle(_ title: String?, fallback: String) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        let fallbackTrimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackTrimmed.isEmpty ? "Course" : fallbackTrimmed
    }
}
