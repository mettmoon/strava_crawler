import Foundation
import Combine
import CourseBoyKit

// MARK: - CourseRoutePoint

/// 사용자가 맵 클릭으로 추가한 경유지 (RoutePoint).
/// 인접 RoutePoint 간 OSRM으로 실제 경로를 계산해 trackSegments에 캐시한다.
struct CourseRoutePoint: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = UUID()
    var lat: Double
    var lon: Double
}

// MARK: - CourseCuePoint

/// 큐시트 항목. 경로 위의 특정 지점에 이름/타입/메모를 달아놓는 포인트.
struct CourseCuePoint: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = UUID()
    var lat: Double
    var lon: Double
    var name: String = ""
    /// TCX CoursePoint PointType 값 (e.g. "Straight", "Left", "Right", "Summit" …)
    var pointType: String = "Straight"
    var notes: String = ""
    /// 코스 시작 기준 누적 거리 (미터). 저장 시 재계산된다.
    var distanceMeters: Double = 0
    init(id: UUID = UUID(), lat: Double, lon: Double, name: String = "", pointType: String = "Straight",
         notes: String = "", distanceMeters: Double = 0) {
        self.id = id; self.lat = lat; self.lon = lon; self.name = name
        self.pointType = pointType; self.notes = notes; self.distanceMeters = distanceMeters
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        lat = try c.decode(Double.self, forKey: .lat)
        lon = try c.decode(Double.self, forKey: .lon)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        pointType = try c.decodeIfPresent(String.self, forKey: .pointType) ?? "Straight"
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        distanceMeters = try c.decodeIfPresent(Double.self, forKey: .distanceMeters) ?? 0
    }
}

// MARK: - CourseSegmentSnapshot

/// 코스를 만들 때 선택한 Strava 구간의 복사용 메타데이터 스냅샷.
/// 좌표/고도 스트림은 제외해 CSB 파일 크기가 불필요하게 커지지 않도록 한다.
struct CourseSegmentSnapshot: Codable, Identifiable, Sendable, Equatable {
    var segmentID: String
    var title: String
    var distanceMeters: Double?
    var averageGradePercent: Double?
    var classification: String

    var id: String { segmentID }

    init(
        segmentID: String,
        title: String,
        distanceMeters: Double?,
        averageGradePercent: Double?,
        classification: String
    ) {
        self.segmentID = segmentID
        self.title = title
        self.distanceMeters = distanceMeters
        self.averageGradePercent = averageGradePercent
        self.classification = classification
    }

    init(segment: SegmentInfo) {
        segmentID = segment.segmentID
        let trimmedTitle = segment.name.trimmingCharacters(in: .whitespacesAndNewlines)
        title = trimmedTitle.isEmpty ? "Segment" : trimmedTitle
        distanceMeters = segment.distanceMeters
            ?? segment.distanceKm.map { $0 * 1_000 }
            ?? Self.parseDistanceMeters(segment.distanceText)
        averageGradePercent = Self.firstNumber(in: segment.avgGrade)

        if let category = Classification.normalizeClimbCategory(segment.climbCategory) {
            classification = category == "HC" ? "HC" : "Cat \(category)"
        } else {
            switch Classification.gradeClass(segment.avgGrade) {
            case .up: classification = "오르막"
            case .flat: classification = "평지"
            case .down: classification = "내리막"
            }
        }
    }

    var clipboardText: String {
        let distance = distanceMeters.map { Self.formatDecimal(max(0, $0) / 1_000, maximumFractionDigits: 2) } ?? "-"
        let grade = averageGradePercent.map {
            String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), $0)
        } ?? "-"
        return "\(title)(\(classification))\n\(distance)km, \(grade)%\nhttps://www.strava.com/segments/\(segmentID)"
    }

    private static func parseDistanceMeters(_ text: String?) -> Double? {
        guard let text, let value = firstNumber(in: text) else { return nil }
        return text.lowercased().contains("km") ? value * 1_000 : value
    }

    private static func firstNumber(in text: String?) -> Double? {
        guard let text,
              let range = text.range(of: #"-?\d+(?:\.\d+)?"#, options: .regularExpression)
        else { return nil }
        return Double(text[range])
    }

    private static func formatDecimal(_ value: Double, maximumFractionDigits: Int) -> String {
        var result = String(
            format: "%.*f",
            locale: Locale(identifier: "en_US_POSIX"),
            maximumFractionDigits,
            value
        )
        while result.last == "0" { result.removeLast() }
        if result.last == "." { result.removeLast() }
        return result
    }
}

// MARK: - TrackPointCodable

/// TrackPoint(Sendable, non-Codable)를 저장하기 위한 경량 Codable 래퍼.
struct TrackPointCodable: Codable, Sendable, Equatable {
    var lat: Double
    var lon: Double
    var ele: Double?
    var time: String?
    var cumKm: Double

    init(lat: Double, lon: Double, ele: Double?, time: String? = nil, cumKm: Double) {
        self.lat = lat
        self.lon = lon
        self.ele = ele
        self.time = time
        self.cumKm = cumKm
    }

    init(_ tp: TrackPoint) {
        lat = tp.lat; lon = tp.lon; ele = tp.ele; time = tp.time; cumKm = tp.cumKm
    }

    var asTrackPoint: TrackPoint { TrackPoint(lat: lat, lon: lon, ele: ele, time: time, cumKm: cumKm) }
}

// MARK: - CourseSection

/// 두 RoutePoint 사이를 잇는 실제 경로 형상.
/// `straight`는 섹션 합치기에서만 생성하며 OSRM 재계산 대상이 아니다.
struct CourseLeg: Codable, Identifiable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case routed
        case straight
    }

    var id: UUID = UUID()
    var kind: Kind = .routed
    var trackPoints: [TrackPointCodable]
}

/// 독립적으로 편집할 수 있는 코스의 경로 단위.
/// 섹션 사이에는 암묵적인 연결이 없으며, 합치기할 때만 straight leg가 생긴다.
struct CourseSection: Codable, Identifiable, Sendable, Equatable {
    var id: UUID = UUID()
    var routePoints: [CourseRoutePoint] = []
    var legs: [CourseLeg] = []
    var cuePoints: [CourseCuePoint] = []

    init(
        id: UUID = UUID(),
        routePoints: [CourseRoutePoint] = [],
        legs: [CourseLeg] = [],
        cuePoints: [CourseCuePoint] = []
    ) {
        self.id = id
        self.routePoints = routePoints
        self.legs = legs
        self.cuePoints = cuePoints
    }

    /// 섹션 내부 트랙포인트. leg 이음새의 중복점은 제거하고 거리를 다시 계산한다.
    var trackPoints: [TrackPoint] {
        var raw: [TrackPointCodable] = []
        for (legIndex, leg) in legs.enumerated() {
            raw.append(contentsOf: legIndex == 0 ? leg.trackPoints : Array(leg.trackPoints.dropFirst()))
        }

        var result: [TrackPoint] = []
        result.reserveCapacity(raw.count)
        var cumKm = 0.0
        for (index, point) in raw.enumerated() {
            if index > 0 {
                let previous = raw[index - 1]
                cumKm += Geo.haversineKm(previous.lat, previous.lon, point.lat, point.lon)
            }
            result.append(TrackPoint(
                lat: point.lat,
                lon: point.lon,
                ele: point.ele,
                time: point.time,
                cumKm: cumKm
            ))
        }
        return result
    }

    var distanceKm: Double { trackPoints.last?.cumKm ?? 0 }

    /// straight leg의 양 끝 고도 차이는 실제 지형을 알 수 없으므로 획득고도에서 제외한다.
    var elevationGainM: Double {
        elevationChange.gain
    }

    var elevationLossM: Double {
        elevationChange.loss
    }

    private var elevationChange: (gain: Double, loss: Double) {
        var gain = 0.0
        var loss = 0.0
        for leg in legs where leg.kind != .straight {
            let points = leg.trackPoints
            guard points.count > 1 else { continue }
            for index in 1 ..< points.count {
                guard let previous = points[index - 1].ele, let current = points[index].ele else { continue }
                let difference = current - previous
                gain += max(0, difference)
                loss += max(0, -difference)
            }
        }
        return (gain, loss)
    }
}

struct CourseSectionTrack: Identifiable, Sendable {
    let id: UUID
    let points: [TrackPoint]
    let courseStartKm: Double
}

// MARK: - CourseRecord

/// 사용자가 직접 만들거나 RouteRecord에서 파생한 코스.
final class CourseRecord: ObservableObject, Identifiable {
    @Published var id: UUID = UUID()
    @Published var title: String = ""
    @Published var createdAt: Date = Date()

    /// 순서가 곧 코스 진행 순서다. 빈 코스도 편집을 위해 빈 섹션 하나를 유지한다.
    @Published var sections: [CourseSection] = [CourseSection()]

    /// "코스로 만들기" 출처 RouteRecord.routeID. 직접 생성이면 nil.
    @Published var sourceRouteID: String?

    /// TCX 파일 열기로 생성된 경우 원본 파일 경로. 직접 생성/Strava 경로 기반이면 nil.
    @Published var sourceFilePath: String?

    /// "코스 만들기"에서 선택한 Strava 구간 정보. CSB 저장 및 클립보드 복사에 사용한다.
    @Published var segmentSnapshots: [CourseSegmentSnapshot] = []

    init(title: String, sourceRouteID: String? = nil, sourceFilePath: String? = nil) {
        self.title = title
        self.sourceRouteID = sourceRouteID
        self.sourceFilePath = sourceFilePath
    }

    // MARK: - 편의 계산

    /// 기존 단일 섹션 생성 코드를 위한 호환 접근자.
    /// 다중 섹션 편집은 반드시 `sections`를 직접 변경한다.
    var routePoints: [CourseRoutePoint] {
        get { sections.flatMap(\.routePoints) }
        set {
            ensureLegacySection()
            sections[0].routePoints = newValue
        }
    }

    var trackSegments: [[TrackPointCodable]] {
        get { sections.flatMap { $0.legs.map(\.trackPoints) } }
        set {
            ensureLegacySection()
            sections[0].legs = newValue.map { CourseLeg(kind: .routed, trackPoints: $0) }
        }
    }

    /// 표시/내보내기용 코스 누적 거리 큐 목록.
    var cuePoints: [CourseCuePoint] {
        get {
            var offsetMeters = 0.0
            var result: [CourseCuePoint] = []
            for section in sections {
                result.append(contentsOf: section.cuePoints.map { cue in
                    var copy = cue
                    copy.distanceMeters += offsetMeters
                    return copy
                })
                offsetMeters += section.distanceKm * 1000
            }
            return result.sorted { $0.distanceMeters < $1.distanceMeters }
        }
        set {
            ensureLegacySection()
            sections[0].cuePoints = newValue.sorted { $0.distanceMeters < $1.distanceMeters }
        }
    }

    private func ensureLegacySection() {
        if sections.count != 1 {
            sections = [CourseSection()]
        }
    }

    var sectionTracks: [CourseSectionTrack] {
        var offset = 0.0
        return sections.map { section in
            let track = CourseSectionTrack(id: section.id, points: section.trackPoints, courseStartKm: offset)
            offset += section.distanceKm
            return track
        }
    }

    var adjustedSectionTrackPoints: [[TrackPoint]] {
        sectionTracks.map { track in
            track.points.map { point in
                TrackPoint(
                    lat: point.lat, lon: point.lon, ele: point.ele, time: point.time,
                    cumKm: track.courseStartKm + point.cumKm
                )
            }
        }
    }

    /// 표시/내보내기 호환용 평탄 트랙. 섹션 사이 공간 거리는 더하지 않는다.
    var allTrackPoints: [TrackPoint] {
        var result: [TrackPoint] = []
        var offset = 0.0
        for section in sections {
            for point in section.trackPoints {
                result.append(TrackPoint(
                    lat: point.lat,
                    lon: point.lon,
                    ele: point.ele,
                    time: point.time,
                    cumKm: offset + point.cumKm
                ))
            }
            offset += section.distanceKm
        }
        return result
    }

    /// 총 거리 (km).
    var totalDistanceKm: Double {
        sections.reduce(0) { $0 + $1.distanceKm }
    }

    /// 획득고도 (m). 고도 데이터가 없으면 0.
    var totalElevationGainM: Double {
        sections.reduce(0) { $0 + $1.elevationGainM }
    }

    var totalElevationLossM: Double {
        sections.reduce(0) { $0 + $1.elevationLossM }
    }

    var segmentClipboardText: String {
        segmentSnapshots.map(\.clipboardText).joined(separator: "\n\n")
    }
}
