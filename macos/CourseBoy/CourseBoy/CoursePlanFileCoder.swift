import Foundation

enum CoursePlanFileError: Error, LocalizedError {
    case missingRoot
    case unsupportedVersion(String)
    case missingRequiredField(String)

    var errorDescription: String? {
        switch self {
        case .missingRoot:
            return "CSB 파일의 루트 요소를 찾을 수 없습니다."
        case .unsupportedVersion(let version):
            return "지원하지 않는 CSB 형식입니다. version=\(version)"
        case .missingRequiredField(let field):
            return "CSB 파일에 필수 값이 없습니다: \(field)"
        }
    }
}

enum CoursePlanFileCoder {
    private static let currentVersion = "3"
    private static let supportedVersions: Set<String> = ["1", "2", "3"]

    static func makeRecord(from data: Data) throws -> CourseRecord {
        let doc = try XMLDocument(data: data)
        guard let root = doc.rootElement(), root.localName == "CoursePlan" else {
            throw CoursePlanFileError.missingRoot
        }

        let version = root.attribute(forName: "version")?.stringValue ?? "1"
        guard supportedVersions.contains(version) else {
            throw CoursePlanFileError.unsupportedVersion(version)
        }

        let metadata = firstChild(of: root, named: "Metadata")
        let title = textChild(of: metadata, named: "Title") ?? "Course"
        let course = CourseRecord(title: title)
        course.id = uuidChild(of: metadata, named: "ID") ?? UUID()
        course.createdAt = dateChild(of: metadata, named: "CreatedAt") ?? Date()
        course.sourceRouteID = nonEmpty(textChild(of: metadata, named: "SourceRouteID"))
        course.sourceFilePath = nonEmpty(textChild(of: metadata, named: "SourceFilePath"))
        course.segmentSnapshots = parseSegmentSnapshots(firstChild(of: root, named: "Segments"))

        if version != "1", let sections = firstChild(of: root, named: "Sections") {
            course.sections = children(of: sections, named: "Section").map(parseSection)
            if course.sections.isEmpty { course.sections = [CourseSection()] }
        } else {
            // v1은 코스 전체를 섹션 하나로 감싸서 읽는다.
            let routePoints = parseRoutePoints(firstChild(of: root, named: "RoutePoints"))
            let legs = children(of: firstChild(of: root, named: "TrackSegments"), named: "TrackSegment")
                .map { CourseLeg(kind: .routed, trackPoints: parseTrackPoints($0)) }
            let cuePoints = parseCuePoints(firstChild(of: root, named: "CuePoints"))
            course.sections = [CourseSection(routePoints: routePoints, legs: legs, cuePoints: cuePoints)]
        }

        return course
    }

    static func data(from course: CourseRecord) throws -> Data {
        let root = XMLElement(name: "CoursePlan")
        root.addAttribute(attribute("version", currentVersion))

        let metadata = XMLElement(name: "Metadata")
        metadata.addChild(textElement("ID", course.id.uuidString))
        metadata.addChild(textElement("Title", course.title))
        metadata.addChild(textElement("CreatedAt", string(from: course.createdAt)))
        if let sourceRouteID = nonEmpty(course.sourceRouteID) {
            metadata.addChild(textElement("SourceRouteID", sourceRouteID))
        }
        if let sourceFilePath = nonEmpty(course.sourceFilePath) {
            metadata.addChild(textElement("SourceFilePath", sourceFilePath))
        }
        root.addChild(metadata)

        if !course.segmentSnapshots.isEmpty {
            let segments = XMLElement(name: "Segments")
            for segment in course.segmentSnapshots {
                let element = XMLElement(name: "Segment")
                element.addAttribute(attribute("id", segment.segmentID))
                element.addChild(textElement("Title", segment.title))
                if let distanceMeters = segment.distanceMeters {
                    element.addChild(textElement("DistanceMeters", decimal(distanceMeters, places: 6)))
                }
                if let averageGradePercent = segment.averageGradePercent {
                    element.addChild(textElement("AverageGradePercent", decimal(averageGradePercent, places: 6)))
                }
                element.addChild(textElement("Classification", segment.classification))
                segments.addChild(element)
            }
            root.addChild(segments)
        }

        let sections = XMLElement(name: "Sections")
        for section in course.sections {
            let sectionElement = XMLElement(name: "Section")
            sectionElement.addAttribute(attribute("id", section.id.uuidString))

            let routePoints = XMLElement(name: "RoutePoints")
            for point in section.routePoints {
                let element = XMLElement(name: "RoutePoint")
                element.addAttribute(attribute("id", point.id.uuidString))
                element.addAttribute(attribute("lat", decimal(point.lat, places: 7)))
                element.addAttribute(attribute("lon", decimal(point.lon, places: 7)))
                routePoints.addChild(element)
            }
            sectionElement.addChild(routePoints)

            let legs = XMLElement(name: "Legs")
            for leg in section.legs {
                let legElement = XMLElement(name: "Leg")
                legElement.addAttribute(attribute("id", leg.id.uuidString))
                legElement.addAttribute(attribute("kind", leg.kind.rawValue))
                appendTrackPoints(leg.trackPoints, to: legElement)
                legs.addChild(legElement)
            }
            sectionElement.addChild(legs)

            let cuePoints = XMLElement(name: "CuePoints")
            for cue in section.cuePoints {
                let element = XMLElement(name: "CuePoint")
                element.addAttribute(attribute("id", cue.id.uuidString))
                element.addAttribute(attribute("lat", decimal(cue.lat, places: 7)))
                element.addAttribute(attribute("lon", decimal(cue.lon, places: 7)))
                element.addAttribute(attribute("pointType", cue.pointType))
                element.addAttribute(attribute("distanceMeters", decimal(cue.distanceMeters, places: 2)))
                element.addChild(textElement("Name", cue.name))
                element.addChild(textElement("Notes", cue.notes))
                cuePoints.addChild(element)
            }
            sectionElement.addChild(cuePoints)
            sections.addChild(sectionElement)
        }
        root.addChild(sections)

        let doc = XMLDocument(rootElement: root)
        doc.characterEncoding = "UTF-8"
        doc.version = "1.0"
        return doc.xmlData(options: [.nodePrettyPrint])
    }

    private static func parseSection(_ element: XMLElement) -> CourseSection {
        let routePoints = parseRoutePoints(firstChild(of: element, named: "RoutePoints"))
        let legs = children(of: firstChild(of: element, named: "Legs"), named: "Leg").map { leg in
            CourseLeg(
                id: uuidAttribute(of: leg, named: "id") ?? UUID(),
                kind: CourseLeg.Kind(rawValue: leg.attribute(forName: "kind")?.stringValue ?? "") ?? .routed,
                trackPoints: parseTrackPoints(leg)
            )
        }
        return CourseSection(
            id: uuidAttribute(of: element, named: "id") ?? UUID(),
            routePoints: routePoints,
            legs: legs,
            cuePoints: parseCuePoints(firstChild(of: element, named: "CuePoints"))
        )
    }

    private static func parseRoutePoints(_ element: XMLElement?) -> [CourseRoutePoint] {
        children(of: element, named: "RoutePoint").map { point in
            CourseRoutePoint(
                id: uuidAttribute(of: point, named: "id") ?? UUID(),
                lat: doubleAttribute(of: point, named: "lat") ?? 0,
                lon: doubleAttribute(of: point, named: "lon") ?? 0
            )
        }
    }

    private static func parseTrackPoints(_ element: XMLElement?) -> [TrackPointCodable] {
        children(of: element, named: "TrackPoint").map { point in
            TrackPointCodable(
                lat: doubleAttribute(of: point, named: "lat") ?? 0,
                lon: doubleAttribute(of: point, named: "lon") ?? 0,
                ele: doubleAttribute(of: point, named: "ele"),
                cumKm: doubleAttribute(of: point, named: "cumKm") ?? 0
            )
        }
    }

    private static func parseCuePoints(_ element: XMLElement?) -> [CourseCuePoint] {
        children(of: element, named: "CuePoint").map { cue in
            CourseCuePoint(
                id: uuidAttribute(of: cue, named: "id") ?? UUID(),
                lat: doubleAttribute(of: cue, named: "lat") ?? 0,
                lon: doubleAttribute(of: cue, named: "lon") ?? 0,
                name: textChild(of: cue, named: "Name") ?? "",
                pointType: cue.attribute(forName: "pointType")?.stringValue ?? "Straight",
                notes: textChild(of: cue, named: "Notes") ?? "",
                distanceMeters: doubleAttribute(of: cue, named: "distanceMeters") ?? 0
            )
        }
    }

    private static func parseSegmentSnapshots(_ element: XMLElement?) -> [CourseSegmentSnapshot] {
        children(of: element, named: "Segment").compactMap { segment in
            guard let segmentID = nonEmpty(segment.attribute(forName: "id")?.stringValue) else { return nil }
            return CourseSegmentSnapshot(
                segmentID: segmentID,
                title: nonEmpty(textChild(of: segment, named: "Title")) ?? "Segment",
                distanceMeters: textChild(of: segment, named: "DistanceMeters").flatMap(Double.init),
                averageGradePercent: textChild(of: segment, named: "AverageGradePercent").flatMap(Double.init),
                classification: nonEmpty(textChild(of: segment, named: "Classification")) ?? "평지"
            )
        }
    }

    private static func appendTrackPoints(_ points: [TrackPointCodable], to parent: XMLElement) {
        for point in points {
            let element = XMLElement(name: "TrackPoint")
            element.addAttribute(attribute("lat", decimal(point.lat, places: 7)))
            element.addAttribute(attribute("lon", decimal(point.lon, places: 7)))
            if let ele = point.ele {
                element.addAttribute(attribute("ele", decimal(ele, places: 2)))
            }
            element.addAttribute(attribute("cumKm", decimal(point.cumKm, places: 6)))
            parent.addChild(element)
        }
    }

    private static func textElement(_ name: String, _ value: String) -> XMLElement {
        XMLElement(name: name, stringValue: value)
    }

    private static func attribute(_ name: String, _ value: String) -> XMLNode {
        XMLNode.attribute(withName: name, stringValue: value) as! XMLNode
    }

    private static func firstChild(of element: XMLElement?, named name: String) -> XMLElement? {
        children(of: element, named: name).first
    }

    private static func children(of element: XMLElement?, named name: String) -> [XMLElement] {
        (element?.children ?? [])
            .compactMap { $0 as? XMLElement }
            .filter { $0.localName == name }
    }

    private static func textChild(of element: XMLElement?, named name: String) -> String? {
        firstChild(of: element, named: name)?.stringValue
    }

    private static func uuidChild(of element: XMLElement?, named name: String) -> UUID? {
        textChild(of: element, named: name).flatMap(UUID.init(uuidString:))
    }

    private static func dateChild(of element: XMLElement?, named name: String) -> Date? {
        textChild(of: element, named: name).flatMap(date(from:))
    }

    private static func uuidAttribute(of element: XMLElement, named name: String) -> UUID? {
        element.attribute(forName: name)?.stringValue.flatMap(UUID.init(uuidString:))
    }

    private static func doubleAttribute(of element: XMLElement, named name: String) -> Double? {
        element.attribute(forName: name)?.stringValue.flatMap(Double.init)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func string(from date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static func date(from string: String) -> Date? {
        isoFormatter.date(from: string) ?? fallbackISOFormatter.date(from: string)
    }

    private static func decimal(_ value: Double, places: Int) -> String {
        String(format: "%.\(places)f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
