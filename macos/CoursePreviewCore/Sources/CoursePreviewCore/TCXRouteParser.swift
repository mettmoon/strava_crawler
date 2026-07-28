import Foundation

final class TCXRouteParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let sourceURL: URL
    private let fallbackTitle: String
    private var elementStack: [String] = []
    private var currentText = ""
    private var courseTitle: String?
    private var rawTrackPoints: [RawRoutePoint] = []
    private var rawCuePoints: [RawCuePoint] = []
    private var currentTrackPoint: ParsedTCXPoint?
    private var currentCoursePoint: ParsedTCXPoint?

    init(data: Data, sourceURL: URL, fallbackTitle: String) {
        self.data = data
        self.sourceURL = sourceURL
        self.fallbackTitle = fallbackTitle
    }

    func course() throws -> LoadedCourse {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true

        guard parser.parse() else {
            let message = parser.parserError?.localizedDescription ?? "TCX 파싱 실패"
            throw RouteFileLoadError.parseFailed(message)
        }

        let trackPoints = normalizedTrackPoints(from: rawTrackPoints)
        guard !trackPoints.isEmpty else { throw RouteFileLoadError.noTrackpoints }

        return LoadedCourse(
            title: RouteFileLoader.normalizedTitle(courseTitle, fallback: fallbackTitle),
            sourceURL: sourceURL,
            fileKind: .tcx,
            routePoints: routeEndpoints(from: trackPoints),
            trackPoints: trackPoints,
            cuePoints: RouteFileLoader.cuePoints(
                from: rawCuePoints,
                trackPoints: trackPoints
            )
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let name = normalizedElementName(localName: elementName, qualifiedName: qName)
        elementStack.append(name)
        currentText = ""

        switch name {
        case "Trackpoint":
            currentTrackPoint = ParsedTCXPoint()
        case "CoursePoint":
            currentCoursePoint = ParsedTCXPoint(pointType: "Generic")
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = normalizedElementName(localName: elementName, qualifiedName: qName)
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = elementStack.dropLast().last
        let grandparent = elementStack.dropLast(2).last

        switch name {
        case "Name" where parent == "Course":
            if courseTitle == nil { courseTitle = text }
        case "Time":
            currentTrackPoint?.time = text
            currentCoursePoint?.time = text
        case "LatitudeDegrees" where parent == "Position":
            if grandparent == "Trackpoint" {
                currentTrackPoint?.lat = Double(text)
            } else if grandparent == "CoursePoint" {
                currentCoursePoint?.lat = Double(text)
            }
        case "LongitudeDegrees" where parent == "Position":
            if grandparent == "Trackpoint" {
                currentTrackPoint?.lon = Double(text)
            } else if grandparent == "CoursePoint" {
                currentCoursePoint?.lon = Double(text)
            }
        case "AltitudeMeters":
            currentTrackPoint?.ele = Double(text)
            currentCoursePoint?.ele = Double(text)
        case "Name" where parent == "CoursePoint":
            currentCoursePoint?.name = text
        case "PointType":
            currentCoursePoint?.pointType = text.isEmpty ? "Generic" : text
        case "Notes":
            currentCoursePoint?.notes = text
        case "Trackpoint":
            if let point = currentTrackPoint?.rawRoutePoint {
                rawTrackPoints.append(point)
            }
            currentTrackPoint = nil
        case "CoursePoint":
            if let cue = currentCoursePoint?.rawCuePoint {
                rawCuePoints.append(cue)
            }
            currentCoursePoint = nil
        default:
            break
        }

        if !elementStack.isEmpty {
            elementStack.removeLast()
        }
        currentText = ""
    }

    private func routeEndpoints(from trackPoints: [TrackPoint]) -> [CourseRoutePoint] {
        guard let first = trackPoints.first, let last = trackPoints.last else { return [] }
        return [
            CourseRoutePoint(lat: first.lat, lon: first.lon),
            CourseRoutePoint(lat: last.lat, lon: last.lon),
        ]
    }
}

private struct ParsedTCXPoint {
    var lat: Double?
    var lon: Double?
    var ele: Double?
    var time: String?
    var name = ""
    var pointType = "Generic"
    var notes = ""

    var rawRoutePoint: RawRoutePoint? {
        guard let lat, let lon else { return nil }
        return RawRoutePoint(lat: lat, lon: lon, ele: ele, time: time)
    }

    var rawCuePoint: RawCuePoint? {
        guard let lat, let lon else { return nil }
        return RawCuePoint(
            lat: lat,
            lon: lon,
            time: time,
            name: name,
            pointType: pointType.isEmpty ? "Generic" : pointType,
            notes: notes
        )
    }
}

func normalizedElementName(localName: String, qualifiedName: String?) -> String {
    let raw = localName.isEmpty ? (qualifiedName ?? "") : localName
    return raw.split(separator: ":").last.map(String.init) ?? raw
}
