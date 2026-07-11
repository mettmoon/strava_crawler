import Foundation
import CourseBoyKit

enum CourseGPXFileError: Error, LocalizedError {
    case parseFailed
    case noTrackpoints

    var errorDescription: String? {
        switch self {
        case .parseFailed:
            return "GPX 파싱 실패"
        case .noTrackpoints:
            return "GPX 파일에 trackpoint 또는 routepoint가 없습니다."
        }
    }
}

enum CourseGPXFileCoder {
    static func makeRecord(from data: Data, fallbackTitle: String, sourceFilePath: String? = nil) throws -> CourseRecord {
        let gpxCourse = try ParsedGPXCourse(data: data)
        let title = normalizedTitle(gpxCourse.title, fallback: fallbackTitle)
        let course = CourseRecord(title: title, sourceFilePath: sourceFilePath)
        course.sections = gpxCourse.trackPointSections.compactMap { points in
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

        for point in gpxCourse.cuePoints {
            guard let match = nearestSectionMatch(
                in: gpxCourse.trackPointSections, lat: point.lat, lon: point.lon
            ) else { continue }
            course.sections[match.sectionIndex].cuePoints.append(CourseCuePoint(
                lat: point.lat,
                lon: point.lon,
                name: point.name,
                pointType: point.pointType,
                notes: point.notes,
                distanceMeters: match.point.cumKm * 1000
            ))
        }
        for index in course.sections.indices {
            course.sections[index].cuePoints.sort { $0.distanceMeters < $1.distanceMeters }
        }

        return course
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

private struct ParsedGPXCourse {
    struct CuePoint {
        var lat: Double
        var lon: Double
        var name: String
        var pointType: String
        var notes: String
    }

    let title: String?
    let trackPoints: [TrackPoint]
    let trackPointSections: [[TrackPoint]]
    let cuePoints: [CuePoint]

    init(data: Data) throws {
        guard let doc = try? XMLDocument(data: data),
              let root = doc.rootElement(),
              root.localName == "gpx" else {
            throw CourseGPXFileError.parseFailed
        }

        title = Self.parseTitle(in: root)
        let rawSections = Self.parseTrackPointCandidateSections(in: root)
        guard !rawSections.isEmpty else { throw CourseGPXFileError.noTrackpoints }

        trackPointSections = rawSections.map(Self.trackPoints(from:))
        trackPoints = Self.flatten(trackPointSections)
        cuePoints = Self.parseCuePoints(in: root)
    }

    private struct PointCandidate {
        var lat: Double
        var lon: Double
        var ele: Double?
        var time: String?
    }

    private static func parseTitle(in root: XMLElement) -> String? {
        let metadataName = firstDirectChild(of: root, named: "metadata")
            .flatMap { textChild(of: $0, named: "name") }
        let trackName = allElements(in: root, localName: "trk")
            .lazy
            .compactMap { textChild(of: $0, named: "name") }
            .first
        let routeName = allElements(in: root, localName: "rte")
            .lazy
            .compactMap { textChild(of: $0, named: "name") }
            .first

        return firstNonEmpty(trackName, routeName, metadataName)
    }

    private static func parseTrackPointCandidateSections(in root: XMLElement) -> [[PointCandidate]] {
        var result: [[PointCandidate]] = []

        for track in allElements(in: root, localName: "trk") {
            let segments = directChildren(of: track, named: "trkseg")
            if segments.isEmpty {
                let points = allElements(in: track, localName: "trkpt").compactMap(parsePoint)
                if !points.isEmpty { result.append(points) }
            } else {
                for segment in segments {
                    let points = directChildren(of: segment, named: "trkpt").compactMap(parsePoint)
                    if !points.isEmpty { result.append(points) }
                }
            }
        }

        if result.isEmpty {
            for route in allElements(in: root, localName: "rte") {
                let points = directChildren(of: route, named: "rtept").compactMap(parsePoint)
                if !points.isEmpty { result.append(points) }
            }
        }

        return result
    }

    private static func trackPoints(from candidates: [PointCandidate]) -> [TrackPoint] {
        var result: [TrackPoint] = []
        var cumKm: Double = 0
        var previous: PointCandidate?

        for point in candidates {
            if let previous {
                cumKm += Geo.haversineKm(previous.lat, previous.lon, point.lat, point.lon)
            }
            result.append(TrackPoint(
                lat: point.lat,
                lon: point.lon,
                ele: point.ele,
                time: point.time,
                cumKm: cumKm
            ))
            previous = point
        }

        return result
    }

    private static func flatten(_ sections: [[TrackPoint]]) -> [TrackPoint] {
        var result: [TrackPoint] = []
        var offset = 0.0
        for section in sections {
            result.append(contentsOf: section.map { point in
                TrackPoint(
                    lat: point.lat, lon: point.lon, ele: point.ele, time: point.time,
                    cumKm: offset + point.cumKm
                )
            })
            offset += section.last?.cumKm ?? 0
        }
        return result
    }

    private static func parseCuePoints(in root: XMLElement) -> [CuePoint] {
        var points = allElements(in: root, localName: "wpt").compactMap { element in
            parseCuePoint(element, defaultName: "Waypoint", includeUnnamed: true)
        }

        let routePoints = allElements(in: root, localName: "rtept").compactMap { element in
            parseCuePoint(element, defaultName: "Route Point", includeUnnamed: false)
        }
        points.append(contentsOf: routePoints)

        return points
    }

    private static func parsePoint(_ element: XMLElement) -> PointCandidate? {
        guard let lat = doubleAttribute(of: element, named: "lat"),
              let lon = doubleAttribute(of: element, named: "lon") else {
            return nil
        }

        return PointCandidate(
            lat: lat,
            lon: lon,
            ele: textChild(of: element, named: "ele").flatMap(Double.init),
            time: textChild(of: element, named: "time")
        )
    }

    private static func parseCuePoint(_ element: XMLElement, defaultName: String, includeUnnamed: Bool) -> CuePoint? {
        guard let lat = doubleAttribute(of: element, named: "lat"),
              let lon = doubleAttribute(of: element, named: "lon") else {
            return nil
        }

        let name = textChild(of: element, named: "name")
        let desc = textChild(of: element, named: "desc")
        let comment = textChild(of: element, named: "cmt")
        let symbol = textChild(of: element, named: "sym")
        let type = textChild(of: element, named: "type")
        let pointName = firstNonEmpty(name, desc, comment, type, symbol)

        guard includeUnnamed || pointName != nil else { return nil }

        let notes = firstNonEmpty(desc, comment) ?? ""
        return CuePoint(
            lat: lat,
            lon: lon,
            name: pointName ?? defaultName,
            pointType: mappedPointType(from: [name, desc, comment, symbol, type]),
            notes: notes
        )
    }

    private static func mappedPointType(from values: [String?]) -> String {
        let text = values.compactMap { $0 }.joined(separator: " ").lowercased()
        if text.contains("water") || text.contains("drink") || text.contains("hydration") || text.contains("급수") {
            return "Water"
        }
        if text.contains("food") || text.contains("cafe") || text.contains("restaurant") || text.contains("보급") {
            return "Food"
        }
        if text.contains("danger") || text.contains("hazard") || text.contains("warning") || text.contains("위험") {
            return "Danger"
        }
        if text.contains("summit") || text.contains("peak") || text.contains("정상") {
            return "Summit"
        }
        if text.contains("left") || text.contains("좌회전") {
            return "Left"
        }
        if text.contains("right") || text.contains("우회전") {
            return "Right"
        }
        if text.contains("straight") || text.contains("직진") {
            return "Straight"
        }
        return "Generic"
    }

    private static func firstDirectChild(of element: XMLElement, named name: String) -> XMLElement? {
        directChildren(of: element, named: name).first
    }

    private static func directChildren(of element: XMLElement, named name: String) -> [XMLElement] {
        (element.children ?? [])
            .compactMap { $0 as? XMLElement }
            .filter { $0.localName == name }
    }

    private static func textChild(of element: XMLElement, named name: String) -> String? {
        firstDirectChild(of: element, named: name)?.stringValue
    }

    private static func doubleAttribute(of element: XMLElement, named name: String) -> Double? {
        element.attribute(forName: name)?.stringValue.flatMap(Double.init)
    }

    private static func allElements(in node: XMLElement, localName: String) -> [XMLElement] {
        var result: [XMLElement] = []
        if node.localName == localName { result.append(node) }
        for child in (node.children ?? []).compactMap({ $0 as? XMLElement }) {
            result.append(contentsOf: allElements(in: child, localName: localName))
        }
        return result
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
