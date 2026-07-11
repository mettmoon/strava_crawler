import Foundation

public let tcxNamespace = "http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"

/// CoursePoint 1개를 만들기 위한 좌표/메타 정보 (Python entries dict 대응).
public struct CoursePointEntry: Sendable {
    public var idx: Int
    public var time: String?
    public var lat: Double
    public var lon: Double
    public var ele: Double?
    public var pointType: String
    public var baseName: String       // 기본 _cued.tcx 의 Name
    public var baseNotes: String      // 기본 _cued.tcx 의 Notes (요약)
    public var segName: String        // 원본 segment 이름 (RWGPS 종료점 정리용)
    public var isStart: Bool
    public var dist: String?
    public var grade: String?
    public var gradeClass: Classification.GradeClass
    public init(idx: Int, time: String? = nil, lat: Double, lon: Double, ele: Double? = nil, pointType: String, baseName: String, baseNotes: String, segName: String, isStart: Bool, dist: String? = nil, grade: String? = nil, gradeClass: Classification.GradeClass) {
        self.idx = idx
        self.time = time
        self.lat = lat
        self.lon = lon
        self.ele = ele
        self.pointType = pointType
        self.baseName = baseName
        self.baseNotes = baseNotes
        self.segName = segName
        self.isStart = isStart
        self.dist = dist
        self.grade = grade
        self.gradeClass = gradeClass
    }
}

public enum TCXError: Error, LocalizedError {
    case parseFailed
    case noCourse
    case noTrackpoints

    public var errorDescription: String? {
        switch self {
        case .parseFailed: return "TCX 파싱 실패"
        case .noCourse: return "TCX 에 <Course> 가 없습니다 (라우트 TCX 가 필요합니다)"
        case .noTrackpoints: return "TCX 에 trackpoint 가 없습니다"
        }
    }
}

/// 라우트 TCX 한 개를 다루는 객체. 트랙포인트 파싱 + CoursePoint 삽입/직렬화.
public final class TCXCourse {
    public struct ParsedCoursePoint: Sendable {
        public var time: String?
        public var lat: Double
        public var lon: Double
        public var ele: Double?
        public var name: String
        public var pointType: String
        public var notes: String?

        public init(time: String? = nil, lat: Double, lon: Double, ele: Double? = nil,
                    name: String, pointType: String, notes: String? = nil) {
            self.time = time
            self.lat = lat
            self.lon = lon
            self.ele = ele
            self.name = name
            self.pointType = pointType
            self.notes = notes
        }
    }

    public let originalData: Data
    public let trackPoints: [TrackPoint]
    public let trackPointSections: [[TrackPoint]]
    public let courseName: String?
    public let coursePoints: [ParsedCoursePoint]

    public init(data: Data) throws {
        self.originalData = data
        guard let doc = try? XMLDocument(data: data) else { throw TCXError.parseFailed }
        guard let course = TCXCourse.firstElement(in: doc.rootElement(), localName: "Course") else {
            throw TCXError.noCourse
        }
        self.courseName = TCXCourse.firstElement(in: course, localName: "Name")?.stringValue
        let sections = TCXCourse.parseTrackpointSections(in: course)
        let pts = TCXCourse.flatten(sections: sections)
        if pts.isEmpty { throw TCXError.noTrackpoints }
        self.trackPointSections = sections
        self.trackPoints = pts
        self.coursePoints = TCXCourse.parseCoursePoints(in: course)
    }

    /// CoursePoint 를 삽입한 새 TCX 데이터 생성 (원본을 다시 파싱하므로 원본 불변).
    /// 반환: (직렬화된 데이터, 삽입된 CoursePoint 수)
    public func build(entries: [CoursePointEntry], forRWGPS: Bool) throws -> (data: Data, count: Int) {
        guard let doc = try? XMLDocument(data: originalData),
              let course = TCXCourse.firstElement(in: doc.rootElement(), localName: "Course") else {
            throw TCXError.parseFailed
        }
        doc.characterEncoding = "UTF-8"
        doc.version = "1.0"

        // 기존 CoursePoint 제거 (중복 방지)
        for child in (course.children ?? []) where child.localName == "CoursePoint" {
            child.detach()
        }

        // 삽입할 CoursePoint 생성 (idx 순 정렬)
        var newCps: [(idx: Int, element: XMLElement)] = []
        for e in entries {
            let element = makeCoursePoint(entry: e, forRWGPS: forRWGPS)
            newCps.append((e.idx, element))
        }
        newCps.sort { $0.idx < $1.idx }

        // TCX 스키마: Course 안에서 CoursePoint 는 Track 다음.
        let children = course.children ?? []
        let lastTrack = children.lastIndex { $0.localName == "Track" }
        let insertAt = lastTrack.map { $0 + 1 } ?? children.count
        for (offset, cp) in newCps.enumerated() {
            course.insertChild(cp.element, at: insertAt + offset)
        }

        let data = doc.xmlData(options: [])
        return (data, newCps.count)
    }

    /// 코스 편집기에서 저장된 큐포인트를 그대로 TCX로 내보낼 때 사용. 이름을 가공하지 않는다.
    public struct CuePointSpec: Sendable {
        public var idx: Int
        public var time: String?
        public var lat: Double
        public var lon: Double
        public var ele: Double?
        public var name: String
        public var pointType: String
        public var notes: String
        public init(idx: Int, time: String? = nil, lat: Double, lon: Double, ele: Double? = nil,
                    name: String, pointType: String, notes: String) {
            self.idx = idx; self.time = time; self.lat = lat; self.lon = lon; self.ele = ele
            self.name = name; self.pointType = pointType; self.notes = notes
        }
    }

    public func buildFromCourse(cuePoints: [CuePointSpec]) throws -> (data: Data, count: Int) {
        guard let doc = try? XMLDocument(data: originalData),
              let course = TCXCourse.firstElement(in: doc.rootElement(), localName: "Course") else {
            throw TCXError.parseFailed
        }
        doc.characterEncoding = "UTF-8"
        doc.version = "1.0"

        for child in (course.children ?? []) where child.localName == "CoursePoint" {
            child.detach()
        }

        let newCps = cuePoints.sorted { $0.idx < $1.idx }.map { c in
            (idx: c.idx, element: Self.makeCoursePointElement(
                name: c.name, time: c.time, lat: c.lat, lon: c.lon, ele: c.ele,
                pointType: c.pointType, notes: c.notes.isEmpty ? nil : c.notes,
                allowEmptyName: true
            ))
        }

        let children = course.children ?? []
        let lastTrack = children.lastIndex { $0.localName == "Track" }
        let insertAt = lastTrack.map { $0 + 1 } ?? children.count
        for (offset, cp) in newCps.enumerated() {
            course.insertChild(cp.element, at: insertAt + offset)
        }

        return (doc.xmlData(options: []), newCps.count)
    }

    public static func buildCourseData(
        title: String,
        trackPoints: [TrackPoint],
        cuePoints: [CuePointSpec]
    ) throws -> (data: Data, count: Int) {
        try buildCourseData(title: title, tracks: [trackPoints], cuePoints: cuePoints)
    }

    /// 섹션별 Track을 보존하는 코스 TCX 생성.
    public static func buildCourseData(
        title: String,
        tracks: [[TrackPoint]],
        cuePoints: [CuePointSpec]
    ) throws -> (data: Data, count: Int) {
        let nonEmptyTracks = tracks.filter { !$0.isEmpty }
        guard !nonEmptyTracks.isEmpty else { throw TCXError.noTrackpoints }

        let root = nsElement("TrainingCenterDatabase")
        root.addNamespace(XMLNode.namespace(withName: "xsi", stringValue: "http://www.w3.org/2001/XMLSchema-instance") as! XMLNode)
        root.addAttribute(XMLNode.attribute(
            withName: "xsi:schemaLocation",
            stringValue: "\(tcxNamespace) http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd"
        ) as! XMLNode)

        let courses = nsElement("Courses")
        let course = nsElement("Course")
        course.addChild(nsElement("Name", title.isEmpty ? "Course" : title))

        for points in nonEmptyTracks {
            let track = nsElement("Track")
            for point in points {
                let tp = nsElement("Trackpoint")
                if let time = point.time, !time.isEmpty {
                    tp.addChild(nsElement("Time", time))
                }
                let pos = nsElement("Position")
                pos.addChild(nsElement("LatitudeDegrees", String(format: "%.7f", point.lat)))
                pos.addChild(nsElement("LongitudeDegrees", String(format: "%.7f", point.lon)))
                tp.addChild(pos)
                if let ele = point.ele {
                    tp.addChild(nsElement("AltitudeMeters", String(format: "%.2f", ele)))
                }
                tp.addChild(nsElement("DistanceMeters", String(format: "%.2f", point.cumKm * 1000)))
                track.addChild(tp)
            }
            course.addChild(track)
        }

        let sortedCues = cuePoints.sorted { $0.idx < $1.idx }
        for cue in sortedCues {
            course.addChild(makeCoursePointElement(
                name: cue.name, time: cue.time, lat: cue.lat, lon: cue.lon, ele: cue.ele,
                pointType: cue.pointType, notes: cue.notes.isEmpty ? nil : cue.notes,
                allowEmptyName: true
            ))
        }

        courses.addChild(course)
        root.addChild(courses)

        let doc = XMLDocument(rootElement: root)
        doc.characterEncoding = "UTF-8"
        doc.version = "1.0"
        return (doc.xmlData(options: []), sortedCues.count)
    }

    // MARK: - CoursePoint 생성

    private func makeCoursePoint(entry e: CoursePointEntry, forRWGPS: Bool) -> XMLElement {
        let name: String
        let notes: String
        let allowEmptyName: Bool

        if forRWGPS {
            if e.isStart {
                let meta = [Classification.normalizeDistanceText(e.dist), Classification.formatGrade(e.grade)]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                    .joined(separator: ", ")
                let prefix = e.gradeClass.arrow + (meta.isEmpty ? "" : meta + " ")
                notes = prefix + e.baseName
            } else {
                notes = "🏁" + Classification.resolveSegmentName(e.segName)
            }
            name = notes
            allowEmptyName = true
        } else {
            name = e.baseName
            notes = e.baseNotes
            allowEmptyName = false
        }
        return Self.makeCoursePointElement(
            name: name, time: e.time, lat: e.lat, lon: e.lon, ele: e.ele,
            pointType: e.pointType, notes: notes, allowEmptyName: allowEmptyName
        )
    }

    static func makeCoursePointElement(
        name: String, time: String?, lat: Double, lon: Double, ele: Double?,
        pointType: String, notes: String?, allowEmptyName: Bool
    ) -> XMLElement {
        let cp = nsElement("CoursePoint")
        let nameText: String
        if allowEmptyName {
            nameText = String(name.prefix(32))
        } else {
            nameText = String((name.isEmpty ? "Segment" : name).prefix(32))
        }
        cp.addChild(nsElement("Name", nameText))
        if let time, !time.isEmpty {
            cp.addChild(nsElement("Time", time))
        }
        let pos = nsElement("Position")
        pos.addChild(nsElement("LatitudeDegrees", String(format: "%.7f", lat)))
        pos.addChild(nsElement("LongitudeDegrees", String(format: "%.7f", lon)))
        cp.addChild(pos)
        if let ele {
            cp.addChild(nsElement("AltitudeMeters", String(format: "%.2f", ele)))
        }
        cp.addChild(nsElement("PointType", pointType))
        if let notes, !notes.isEmpty {
            cp.addChild(nsElement("Notes", String(notes.prefix(255))))
        }
        return cp
    }

    // MARK: - 파싱 유틸

    static func parseTrackpoints(in course: XMLElement) -> [TrackPoint] {
        flatten(sections: parseTrackpointSections(in: course))
    }

    static func parseTrackpointSections(in course: XMLElement) -> [[TrackPoint]] {
        let tracks = allElements(in: course, localName: "Track")
        if tracks.isEmpty {
            let points = parseSingleTrack(in: course)
            return points.isEmpty ? [] : [points]
        }
        return tracks.map { parseSingleTrack(in: $0) }.filter { !$0.isEmpty }
    }

    private static func parseSingleTrack(in element: XMLElement) -> [TrackPoint] {
        var pts: [TrackPoint] = []
        var cum = 0.0
        var prev: (Double, Double)?
        for tp in allElements(in: element, localName: "Trackpoint") {
            var lat: Double?, lon: Double?, ele: Double?, time: String?
            for child in (tp.children ?? []).compactMap({ $0 as? XMLElement }) {
                switch child.localName {
                case "Position":
                    for c in (child.children ?? []).compactMap({ $0 as? XMLElement }) {
                        if c.localName == "LatitudeDegrees" { lat = c.stringValue.flatMap(Double.init) }
                        else if c.localName == "LongitudeDegrees" { lon = c.stringValue.flatMap(Double.init) }
                    }
                case "AltitudeMeters":
                    ele = child.stringValue.flatMap(Double.init)
                case "Time":
                    time = child.stringValue
                default:
                    break
                }
            }
            guard let lat, let lon else { continue }
            if let p = prev { cum += Geo.haversineKm(p.0, p.1, lat, lon) }
            pts.append(TrackPoint(lat: lat, lon: lon, ele: ele, time: time, cumKm: cum))
            prev = (lat, lon)
        }
        return pts
    }

    private static func flatten(sections: [[TrackPoint]]) -> [TrackPoint] {
        var result: [TrackPoint] = []
        var offset = 0.0
        for section in sections {
            for point in section {
                var copy = point
                copy.cumKm += offset
                result.append(copy)
            }
            offset += section.last?.cumKm ?? 0
        }
        return result
    }

    static func parseCoursePoints(in course: XMLElement) -> [ParsedCoursePoint] {
        var points: [ParsedCoursePoint] = []
        for cp in allElements(in: course, localName: "CoursePoint") {
            var name = ""
            var time: String?
            var lat: Double?
            var lon: Double?
            var ele: Double?
            var pointType = "Generic"
            var notes: String?

            for child in (cp.children ?? []).compactMap({ $0 as? XMLElement }) {
                switch child.localName {
                case "Name":
                    name = child.stringValue ?? ""
                case "Time":
                    time = child.stringValue
                case "Position":
                    for c in (child.children ?? []).compactMap({ $0 as? XMLElement }) {
                        if c.localName == "LatitudeDegrees" { lat = c.stringValue.flatMap(Double.init) }
                        else if c.localName == "LongitudeDegrees" { lon = c.stringValue.flatMap(Double.init) }
                    }
                case "AltitudeMeters":
                    ele = child.stringValue.flatMap(Double.init)
                case "PointType":
                    pointType = child.stringValue ?? "Generic"
                case "Notes":
                    notes = child.stringValue
                default:
                    break
                }
            }

            guard let lat, let lon else { continue }
            points.append(ParsedCoursePoint(
                time: time,
                lat: lat,
                lon: lon,
                ele: ele,
                name: name,
                pointType: pointType,
                notes: notes
            ))
        }
        return points
    }

    static func firstElement(in node: XMLElement?, localName: String) -> XMLElement? {
        guard let node else { return nil }
        if node.localName == localName { return node }
        for child in (node.children ?? []).compactMap({ $0 as? XMLElement }) {
            if let found = firstElement(in: child, localName: localName) { return found }
        }
        return nil
    }

    static func allElements(in node: XMLElement, localName: String) -> [XMLElement] {
        var result: [XMLElement] = []
        if node.localName == localName { result.append(node) }
        for child in (node.children ?? []).compactMap({ $0 as? XMLElement }) {
            result.append(contentsOf: allElements(in: child, localName: localName))
        }
        return result
    }
}

/// 기본 네임스페이스(TCX) 에 속한 XMLElement 생성.
func nsElement(_ name: String, _ text: String? = nil) -> XMLElement {
    let e = XMLElement(name: name, uri: tcxNamespace)
    if let text { e.stringValue = text }
    return e
}
