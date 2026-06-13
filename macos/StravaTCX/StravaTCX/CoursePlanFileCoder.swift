import Foundation

enum CoursePlanFileError: Error, LocalizedError {
    case missingRoot
    case unsupportedVersion(String)
    case missingRequiredField(String)

    var errorDescription: String? {
        switch self {
        case .missingRoot:
            return "CPN 파일의 루트 요소를 찾을 수 없습니다."
        case .unsupportedVersion(let version):
            return "지원하지 않는 CPN 형식입니다. version=\(version)"
        case .missingRequiredField(let field):
            return "CPN 파일에 필수 값이 없습니다: \(field)"
        }
    }
}

enum CoursePlanFileCoder {
    private static let currentVersion = "1"

    static func makeRecord(from data: Data) throws -> CourseRecord {
        let doc = try XMLDocument(data: data)
        guard let root = doc.rootElement(), root.localName == "CoursePlan" else {
            throw CoursePlanFileError.missingRoot
        }

        let version = root.attribute(forName: "version")?.stringValue ?? "1"
        guard version == currentVersion else {
            throw CoursePlanFileError.unsupportedVersion(version)
        }

        let metadata = firstChild(of: root, named: "Metadata")
        let title = textChild(of: metadata, named: "Title") ?? "Course"
        let course = CourseRecord(title: title)
        course.id = uuidChild(of: metadata, named: "ID") ?? UUID()
        course.createdAt = dateChild(of: metadata, named: "CreatedAt") ?? Date()
        course.sourceRouteID = nonEmpty(textChild(of: metadata, named: "SourceRouteID"))
        course.sourceFilePath = nonEmpty(textChild(of: metadata, named: "SourceFilePath"))

        if let routePoints = firstChild(of: root, named: "RoutePoints") {
            course.routePoints = children(of: routePoints, named: "RoutePoint").map { element in
                CourseRoutePoint(
                    id: uuidAttribute(of: element, named: "id") ?? UUID(),
                    lat: doubleAttribute(of: element, named: "lat") ?? 0,
                    lon: doubleAttribute(of: element, named: "lon") ?? 0
                )
            }
        }

        if let trackSegments = firstChild(of: root, named: "TrackSegments") {
            course.trackSegments = children(of: trackSegments, named: "TrackSegment").map { segment in
                children(of: segment, named: "TrackPoint").map { point in
                    TrackPointCodable(
                        lat: doubleAttribute(of: point, named: "lat") ?? 0,
                        lon: doubleAttribute(of: point, named: "lon") ?? 0,
                        ele: doubleAttribute(of: point, named: "ele"),
                        cumKm: doubleAttribute(of: point, named: "cumKm") ?? 0
                    )
                }
            }
        }

        if let cuePoints = firstChild(of: root, named: "CuePoints") {
            course.cuePoints = children(of: cuePoints, named: "CuePoint").map { element in
                CourseCuePoint(
                    id: uuidAttribute(of: element, named: "id") ?? UUID(),
                    lat: doubleAttribute(of: element, named: "lat") ?? 0,
                    lon: doubleAttribute(of: element, named: "lon") ?? 0,
                    name: textChild(of: element, named: "Name") ?? "",
                    pointType: element.attribute(forName: "pointType")?.stringValue ?? "Straight",
                    notes: textChild(of: element, named: "Notes") ?? "",
                    distanceMeters: doubleAttribute(of: element, named: "distanceMeters") ?? 0
                )
            }
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

        let routePoints = XMLElement(name: "RoutePoints")
        for point in course.routePoints {
            let element = XMLElement(name: "RoutePoint")
            element.addAttribute(attribute("id", point.id.uuidString))
            element.addAttribute(attribute("lat", decimal(point.lat, places: 7)))
            element.addAttribute(attribute("lon", decimal(point.lon, places: 7)))
            routePoints.addChild(element)
        }
        root.addChild(routePoints)

        let trackSegments = XMLElement(name: "TrackSegments")
        for segment in course.trackSegments {
            let segmentElement = XMLElement(name: "TrackSegment")
            for point in segment {
                let element = XMLElement(name: "TrackPoint")
                element.addAttribute(attribute("lat", decimal(point.lat, places: 7)))
                element.addAttribute(attribute("lon", decimal(point.lon, places: 7)))
                if let ele = point.ele {
                    element.addAttribute(attribute("ele", decimal(ele, places: 2)))
                }
                element.addAttribute(attribute("cumKm", decimal(point.cumKm, places: 6)))
                segmentElement.addChild(element)
            }
            trackSegments.addChild(segmentElement)
        }
        root.addChild(trackSegments)

        let cuePoints = XMLElement(name: "CuePoints")
        for cue in course.cuePoints {
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
        root.addChild(cuePoints)

        let doc = XMLDocument(rootElement: root)
        doc.characterEncoding = "UTF-8"
        doc.version = "1.0"
        return doc.xmlData(options: [.nodePrettyPrint])
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
