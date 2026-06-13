import Foundation
import Combine
import StravaTCXKit

// MARK: - CourseRoutePoint

/// 사용자가 맵 클릭으로 추가한 경유지 (RoutePoint).
/// 인접 RoutePoint 간 OSRM으로 실제 경로를 계산해 trackSegments에 캐시한다.
struct CourseRoutePoint: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var lat: Double
    var lon: Double
}

// MARK: - CourseCuePoint

/// 큐시트 항목. 경로 위의 특정 지점에 이름/타입/메모를 달아놓는 포인트.
struct CourseCuePoint: Codable, Identifiable, Sendable {
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

// MARK: - TrackPointCodable

/// TrackPoint(Sendable, non-Codable)를 저장하기 위한 경량 Codable 래퍼.
struct TrackPointCodable: Codable, Sendable {
    var lat: Double
    var lon: Double
    var ele: Double?
    var cumKm: Double

    init(lat: Double, lon: Double, ele: Double?, cumKm: Double) {
        self.lat = lat
        self.lon = lon
        self.ele = ele
        self.cumKm = cumKm
    }

    init(_ tp: TrackPoint) {
        lat = tp.lat; lon = tp.lon; ele = tp.ele; cumKm = tp.cumKm
    }

    var asTrackPoint: TrackPoint { TrackPoint(lat: lat, lon: lon, ele: ele, time: nil, cumKm: cumKm) }
}

// MARK: - CourseRecord

/// 사용자가 직접 만들거나 RouteRecord에서 파생한 코스.
final class CourseRecord: ObservableObject, Identifiable {
    @Published var id: UUID = UUID()
    @Published var title: String = ""
    @Published var createdAt: Date = Date()

    /// 경유지 목록. 순서가 경로의 순서.
    @Published var routePoints: [CourseRoutePoint] = []

    /// routePoints[i] → routePoints[i+1] 구간의 OSRM 계산 결과.
    /// trackSegments.count == max(0, routePoints.count - 1)
    @Published var trackSegments: [[TrackPointCodable]] = []

    /// 큐시트 항목 목록.
    @Published var cuePoints: [CourseCuePoint] = []

    /// "코스로 만들기" 출처 RouteRecord.routeID. 직접 생성이면 nil.
    @Published var sourceRouteID: String?

    /// TCX 파일 열기로 생성된 경우 원본 파일 경로. 직접 생성/Strava 경로 기반이면 nil.
    @Published var sourceFilePath: String?

    init(title: String, sourceRouteID: String? = nil, sourceFilePath: String? = nil) {
        self.title = title
        self.sourceRouteID = sourceRouteID
        self.sourceFilePath = sourceFilePath
    }

    // MARK: - 편의 계산

    /// 전체 트랙포인트 (모든 구간 이어붙임, 구간 이음새 중복 제거 후 cumKm 재계산).
    var allTrackPoints: [TrackPoint] {
        var raw: [TrackPointCodable] = []
        for (segIdx, seg) in trackSegments.enumerated() {
            let slice = segIdx == 0 ? seg : Array(seg.dropFirst())
            raw.append(contentsOf: slice)
        }
        // cumKm 재계산
        var result: [TrackPoint] = []
        var cumKm: Double = 0
        for (i, tp) in raw.enumerated() {
            if i > 0 {
                let prev = raw[i - 1]
                cumKm += Geo.haversineKm(prev.lat, prev.lon, tp.lat, tp.lon)
            }
            result.append(TrackPoint(lat: tp.lat, lon: tp.lon, ele: tp.ele, time: nil, cumKm: cumKm))
        }
        return result
    }

    /// 총 거리 (km).
    var totalDistanceKm: Double {
        allTrackPoints.last?.cumKm ?? 0
    }

    /// 획득고도 (m). 고도 데이터가 없으면 0.
    var totalElevationGainM: Double {
        let pts = allTrackPoints
        var gain: Double = 0
        guard pts.count > 1 else { return gain }
        for i in 1 ..< pts.count {
            guard let prev = pts[i - 1].ele, let curr = pts[i].ele else { continue }
            let diff = curr - prev
            if diff > 0 { gain += diff }
        }
        return gain
    }
}
