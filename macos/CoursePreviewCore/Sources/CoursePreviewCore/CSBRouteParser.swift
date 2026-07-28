import Foundation

final class CSBRouteParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let sourceURL: URL
    private let fallbackTitle: String
    private var elementStack: [String] = []
    private var currentText = ""
    private var rootFound = false
    private var version = "1"
    private var title: String?
    private var rawTrackPoints: [RawRoutePoint] = []
    private var rawCuePoints: [RawCuePoint] = []
    private var currentTrackPoint: RawRoutePoint?
    private var currentCuePoint: ParsedCSBCuePoint?

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
            let message = parser.parserError?.localizedDescription ?? "CSB 파싱 실패"
            throw RouteFileLoadError.parseFailed(message)
        }
        guard rootFound else {
            throw RouteFileLoadError.parseFailed("CSB 파일의 루트 요소를 찾을 수 없습니다.")
        }
        guard ["1", "2", "3"].contains(version) else {
            throw RouteFileLoadError.parseFailed("지원하지 않는 CSB 형식입니다. version=\(version)")
        }

        let trackPoints = normalizedTrackPoints(from: rawTrackPoints)
        guard !trackPoints.isEmpty else { throw RouteFileLoadError.noTrackpoints }

        return LoadedCourse(
            title: RouteFileLoader.normalizedTitle(title, fallback: fallbackTitle),
            sourceURL: sourceURL,
            fileKind: .csb,
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

        if elementStack.count == 1, name == "CoursePlan" {
            rootFound = true
            version = attributeDict["version"] ?? "1"
        }

        switch name {
        case "TrackPoint":
            guard let lat = Double(attributeDict["lat"] ?? ""),
                  let lon = Double(attributeDict["lon"] ?? "") else {
                return
            }
            currentTrackPoint = RawRoutePoint(
                lat: lat,
                lon: lon,
                ele: Double(attributeDict["ele"] ?? ""),
                time: attributeDict["time"]
            )
        case "CuePoint":
            guard let lat = Double(attributeDict["lat"] ?? ""),
                  let lon = Double(attributeDict["lon"] ?? "") else {
                return
            }
            currentCuePoint = ParsedCSBCuePoint(
                lat: lat,
                lon: lon,
                pointType: attributeDict["pointType"] ?? "Generic",
                distanceMeters: Double(attributeDict["distanceMeters"] ?? "")
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
        case "Title" where parent == "Metadata":
            title = text
        case "Name" where parent == "CuePoint":
            currentCuePoint?.name = text
        case "Notes" where parent == "CuePoint":
            currentCuePoint?.notes = text
        case "TrackPoint":
            if let point = currentTrackPoint {
                rawTrackPoints.append(point)
            }
            currentTrackPoint = nil
        case "CuePoint":
            if let cue = currentCuePoint {
                rawCuePoints.append(cue.rawCuePoint)
            }
            currentCuePoint = nil
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

private struct ParsedCSBCuePoint {
    var lat: Double
    var lon: Double
    var name = ""
    var notes = ""
    var pointType: String
    var distanceMeters: Double?

    var rawCuePoint: RawCuePoint {
        RawCuePoint(
            lat: lat,
            lon: lon,
            name: name,
            pointType: pointType,
            notes: notes,
            distanceMeters: distanceMeters
        )
    }
}
