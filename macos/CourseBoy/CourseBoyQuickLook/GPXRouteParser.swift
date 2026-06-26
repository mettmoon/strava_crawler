import Foundation

final class GPXRouteParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let sourceURL: URL
    private let fallbackTitle: String

    private var elementStack: [String] = []
    private var currentText = ""

    private var metadataTitle: String?
    private var trackTitle: String?
    private var routeTitle: String?

    private var trackCandidates: [RawRoutePoint] = []
    private var routeCandidates: [RawRoutePoint] = []
    private var waypointCandidates: [RawCuePoint] = []
    private var routeCueCandidates: [RawCuePoint] = []

    private var currentTrackPoint: ParsedGPXPoint?
    private var currentRoutePoint: ParsedGPXPoint?
    private var currentWaypoint: ParsedGPXPoint?

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
            let message = parser.parserError?.localizedDescription ?? "GPX 파싱 실패"
            throw RouteFileLoadError.parseFailed(message)
        }

        let rawTrack = trackCandidates.isEmpty ? routeCandidates : trackCandidates
        let trackPoints = normalizedTrackPoints(from: rawTrack)
        guard !trackPoints.isEmpty else { throw RouteFileLoadError.noTrackpoints }

        let title = firstNonEmpty(trackTitle, routeTitle, metadataTitle)
        let cues = RouteFileLoader.cuePoints(
            from: waypointCandidates + routeCueCandidates,
            trackPoints: trackPoints
        )

        return LoadedCourse(
            title: RouteFileLoader.normalizedTitle(title, fallback: fallbackTitle),
            sourceURL: sourceURL,
            fileKind: .gpx,
            routePoints: routeEndpoints(from: trackPoints),
            trackPoints: trackPoints,
            cuePoints: cues
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
        case "trkpt":
            currentTrackPoint = ParsedGPXPoint(
                lat: Double(attributeDict["lat"] ?? ""),
                lon: Double(attributeDict["lon"] ?? "")
            )
        case "rtept":
            currentRoutePoint = ParsedGPXPoint(
                lat: Double(attributeDict["lat"] ?? ""),
                lon: Double(attributeDict["lon"] ?? "")
            )
        case "wpt":
            currentWaypoint = ParsedGPXPoint(
                lat: Double(attributeDict["lat"] ?? ""),
                lon: Double(attributeDict["lon"] ?? "")
            )
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

        switch name {
        case "name" where parent == "metadata":
            metadataTitle = firstNonEmpty(metadataTitle, text)
        case "name" where parent == "trk":
            trackTitle = firstNonEmpty(trackTitle, text)
        case "name" where parent == "rte":
            routeTitle = firstNonEmpty(routeTitle, text)
        case "ele":
            currentTrackPoint?.ele = Double(text)
            currentRoutePoint?.ele = Double(text)
            currentWaypoint?.ele = Double(text)
        case "time":
            currentTrackPoint?.time = text
            currentRoutePoint?.time = text
            currentWaypoint?.time = text
        case "name":
            currentRoutePoint?.name = text
            currentWaypoint?.name = text
        case "desc":
            currentRoutePoint?.desc = text
            currentWaypoint?.desc = text
        case "cmt":
            currentRoutePoint?.comment = text
            currentWaypoint?.comment = text
        case "sym":
            currentRoutePoint?.symbol = text
            currentWaypoint?.symbol = text
        case "type":
            currentRoutePoint?.type = text
            currentWaypoint?.type = text
        case "trkpt":
            if let point = currentTrackPoint?.rawRoutePoint {
                trackCandidates.append(point)
            }
            currentTrackPoint = nil
        case "rtept":
            if let point = currentRoutePoint?.rawRoutePoint {
                routeCandidates.append(point)
            }
            if let cue = currentRoutePoint?.rawCuePoint(defaultName: "Route Point", includeUnnamed: false) {
                routeCueCandidates.append(cue)
            }
            currentRoutePoint = nil
        case "wpt":
            if let cue = currentWaypoint?.rawCuePoint(defaultName: "Waypoint", includeUnnamed: true) {
                waypointCandidates.append(cue)
            }
            currentWaypoint = nil
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

private struct ParsedGPXPoint {
    var lat: Double?
    var lon: Double?
    var ele: Double?
    var time: String?
    var name: String?
    var desc: String?
    var comment: String?
    var symbol: String?
    var type: String?

    var rawRoutePoint: RawRoutePoint? {
        guard let lat, let lon else { return nil }
        return RawRoutePoint(lat: lat, lon: lon, ele: ele, time: time)
    }

    func rawCuePoint(defaultName: String, includeUnnamed: Bool) -> RawCuePoint? {
        guard let lat, let lon else { return nil }

        let pointName = firstNonEmpty(name, desc, comment, type, symbol)
        guard includeUnnamed || pointName != nil else { return nil }

        return RawCuePoint(
            lat: lat,
            lon: lon,
            name: pointName ?? defaultName,
            pointType: mappedPointType(from: [name, desc, comment, symbol, type]),
            notes: firstNonEmpty(desc, comment) ?? ""
        )
    }

    private func mappedPointType(from values: [String?]) -> String {
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
}

func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return trimmed
        }
    }
    return nil
}
