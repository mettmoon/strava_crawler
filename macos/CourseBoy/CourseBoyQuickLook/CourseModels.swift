import CoreLocation
import Foundation
import SwiftUI
import UIKit

struct LoadedCourse: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var sourceURL: URL
    var fileKind: RouteFileKind
    var routePoints: [CourseRoutePoint]
    var trackPoints: [TrackPoint]
    var cuePoints: [CourseCuePoint]

    var totalDistanceKm: Double {
        trackPoints.last?.cumKm ?? 0
    }

    var elevationStats: CourseElevationStats {
        CourseElevationStats(trackPoints: trackPoints)
    }

    var sortedCuePoints: [CourseCuePoint] {
        cuePoints.sorted { $0.distanceMeters < $1.distanceMeters }
    }
}

enum RouteFileKind: String {
    case gpx = "GPX"
    case tcx = "TCX"
}

struct CourseRoutePoint: Identifiable, Equatable {
    var id = UUID()
    var lat: Double
    var lon: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

struct CourseCuePoint: Identifiable, Equatable {
    var id = UUID()
    var lat: Double
    var lon: Double
    var name: String
    var pointType: String
    var notes: String
    var distanceMeters: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? cuePointLabel(for: pointType) : name
    }

    var distanceKm: Double {
        distanceMeters / 1000
    }
}

struct TrackPoint: Equatable {
    var lat: Double
    var lon: Double
    var ele: Double?
    var time: String?
    var cumKm: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

struct CourseProfileSelection: Equatable {
    var trackIndex: Int
    var lat: Double
    var lon: Double
    var distanceKm: Double
    var elevationMeters: Double?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    init(trackIndex: Int, point: TrackPoint) {
        self.trackIndex = trackIndex
        self.lat = point.lat
        self.lon = point.lon
        self.distanceKm = point.cumKm
        self.elevationMeters = point.ele
    }

    init(trackIndex: Int, lat: Double, lon: Double, distanceKm: Double, elevationMeters: Double?) {
        self.trackIndex = trackIndex
        self.lat = lat
        self.lon = lon
        self.distanceKm = distanceKm
        self.elevationMeters = elevationMeters
    }
}

enum CourseTrackEndpointKind {
    case start
    case end

    var title: String {
        switch self {
        case .start: return "시작점"
        case .end: return "종료점"
        }
    }
}

extension CourseProfileSelection {
    func endpointKind(in course: LoadedCourse) -> CourseTrackEndpointKind? {
        let count = course.trackPoints.count
        guard count > 0 else { return nil }
        if trackIndex == 0 { return .start }
        if count > 1, trackIndex == count - 1 { return .end }
        return nil
    }
}

enum Geo {
    static let earthRadiusKm = 6371.0088

    static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return earthRadiusKm * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    static func nearestIndex(_ pts: [TrackPoint], lat: Double?, lon: Double?) -> Int? {
        guard let lat, let lon, !pts.isEmpty else { return nil }
        var bestIndex: Int?
        var bestDistance = Double.infinity
        for index in pts.indices {
            let distance = haversineKm(pts[index].lat, pts[index].lon, lat, lon)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    static func nearestIndex(_ pts: [TrackPoint], distanceKm: Double) -> Int? {
        guard !pts.isEmpty, distanceKm.isFinite else { return nil }
        var bestIndex = 0
        var bestDistance = abs(pts[0].cumKm - distanceKm)
        for index in pts.indices.dropFirst() {
            let distance = abs(pts[index].cumKm - distanceKm)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }
}

struct CourseElevationStats: Equatable {
    var min: Double?
    var max: Double?
    var span: Double?
    var ascent: Double?
    var descent: Double?
    var hasData: Bool

    init(trackPoints pts: [TrackPoint]) {
        let elevations = pts.compactMap(\.ele)
        let minEle = elevations.min()
        let maxEle = elevations.max()
        min = minEle
        max = maxEle
        span = minEle.flatMap { low in maxEle.map { Swift.max(0, $0 - low) } }
        hasData = !elevations.isEmpty

        guard pts.count > 1 else {
            ascent = nil
            descent = nil
            return
        }

        var up = 0.0
        var down = 0.0
        var hasPair = false
        for index in 1..<pts.count {
            guard let previous = pts[index - 1].ele, let current = pts[index].ele else { continue }
            hasPair = true
            let delta = current - previous
            if delta > 0 {
                up += delta
            } else {
                down += -delta
            }
        }
        ascent = hasPair ? up : nil
        descent = hasPair ? down : nil
    }
}

struct RouteElevationProgressStats: Equatable {
    var ascentFromStart: Double
    var descentFromStart: Double
    var ascentToEnd: Double
    var descentToEnd: Double
}

struct RouteElevationProgress: Equatable {
    private var cumulativeAscent: [Double]
    private var cumulativeDescent: [Double]
    private var elevationPairCounts: [Int]

    init(trackPoints pts: [TrackPoint]) {
        guard !pts.isEmpty else {
            cumulativeAscent = []
            cumulativeDescent = []
            elevationPairCounts = []
            return
        }

        cumulativeAscent = Array(repeating: 0, count: pts.count)
        cumulativeDescent = Array(repeating: 0, count: pts.count)
        elevationPairCounts = Array(repeating: 0, count: pts.count)

        guard pts.count > 1 else { return }
        for index in 1..<pts.count {
            cumulativeAscent[index] = cumulativeAscent[index - 1]
            cumulativeDescent[index] = cumulativeDescent[index - 1]
            elevationPairCounts[index] = elevationPairCounts[index - 1]

            guard let previous = pts[index - 1].ele, let current = pts[index].ele else { continue }
            elevationPairCounts[index] += 1
            let delta = current - previous
            if delta > 0 {
                cumulativeAscent[index] += delta
            } else {
                cumulativeDescent[index] += -delta
            }
        }
    }

    var hasElevationData: Bool {
        (elevationPairCounts.last ?? 0) > 0
    }

    func stats(at index: Int?) -> RouteElevationProgressStats? {
        guard hasElevationData, let index, !cumulativeAscent.isEmpty else { return nil }
        let clamped = min(max(index, 0), cumulativeAscent.count - 1)
        let totalAscent = cumulativeAscent.last ?? 0
        let totalDescent = cumulativeDescent.last ?? 0
        return RouteElevationProgressStats(
            ascentFromStart: cumulativeAscent[clamped],
            descentFromStart: cumulativeDescent[clamped],
            ascentToEnd: max(0, totalAscent - cumulativeAscent[clamped]),
            descentToEnd: max(0, totalDescent - cumulativeDescent[clamped])
        )
    }

    func stats(atDistanceKm distanceKm: Double, trackPoints pts: [TrackPoint]) -> RouteElevationProgressStats? {
        guard hasElevationData,
              pts.count == cumulativeAscent.count,
              !pts.isEmpty else {
            return nil
        }

        guard pts.count > 1 else {
            return stats(at: 0)
        }

        let totalAscent = cumulativeAscent.last ?? 0
        let totalDescent = cumulativeDescent.last ?? 0
        let firstKm = pts[0].cumKm
        let lastKm = pts[pts.count - 1].cumKm
        let clampedKm = min(max(distanceKm, firstKm), lastKm)

        if clampedKm <= firstKm {
            return stats(
                ascentFromStart: cumulativeAscent[0],
                descentFromStart: cumulativeDescent[0],
                totalAscent: totalAscent,
                totalDescent: totalDescent
            )
        }

        for index in 1..<pts.count where clampedKm <= pts[index].cumKm {
            let previousKm = pts[index - 1].cumKm
            let currentKm = pts[index].cumKm
            let ratio = currentKm > previousKm
                ? min(max((clampedKm - previousKm) / (currentKm - previousKm), 0), 1)
                : 0
            let ascentFromStart = cumulativeAscent[index - 1]
                + (cumulativeAscent[index] - cumulativeAscent[index - 1]) * ratio
            let descentFromStart = cumulativeDescent[index - 1]
                + (cumulativeDescent[index] - cumulativeDescent[index - 1]) * ratio

            return stats(
                ascentFromStart: ascentFromStart,
                descentFromStart: descentFromStart,
                totalAscent: totalAscent,
                totalDescent: totalDescent
            )
        }

        return stats(
            ascentFromStart: totalAscent,
            descentFromStart: totalDescent,
            totalAscent: totalAscent,
            totalDescent: totalDescent
        )
    }

    private func stats(
        ascentFromStart: Double,
        descentFromStart: Double,
        totalAscent: Double,
        totalDescent: Double
    ) -> RouteElevationProgressStats {
        RouteElevationProgressStats(
            ascentFromStart: ascentFromStart,
            descentFromStart: descentFromStart,
            ascentToEnd: max(0, totalAscent - ascentFromStart),
            descentToEnd: max(0, totalDescent - descentFromStart)
        )
    }
}

let cuePointTypes: [(value: String, label: String)] = [
    ("Generic", "일반 지점"),
    ("Summit", "정상"),
    ("Valley", "계곡"),
    ("Water", "급수대"),
    ("Food", "보급소"),
    ("Danger", "위험 구간"),
    ("Left", "좌회전"),
    ("Right", "우회전"),
    ("Straight", "직진"),
    ("First Aid", "응급 의료"),
    ("4th Category", "4등급 오르막"),
    ("3rd Category", "3등급 오르막"),
    ("2nd Category", "2등급 오르막"),
    ("1st Category", "1등급 오르막"),
    ("Hors Category", "HC급 오르막"),
    ("Sprint", "스프린트 구간"),
]

func cuePointLabel(for value: String) -> String {
    cuePointTypes.first { $0.value == value }?.label ?? "알수없음(\(value))"
}

struct CuePointGlyph {
    var symbol: String?
    var text: String?
    var color: Color
    var uiColor: UIColor
}

func cuePointGlyph(for value: String) -> CuePointGlyph {
    switch value {
    case "Summit":
        return .init(symbol: "mountain.2.fill", text: nil, color: .green, uiColor: .systemGreen)
    case "Valley":
        return .init(symbol: "arrow.down.to.line", text: nil, color: .teal, uiColor: .systemTeal)
    case "Water":
        return .init(symbol: "drop.fill", text: nil, color: .blue, uiColor: .systemBlue)
    case "Food":
        return .init(symbol: "fork.knife", text: nil, color: .orange, uiColor: .systemOrange)
    case "Danger":
        return .init(symbol: "exclamationmark.triangle.fill", text: nil, color: .red, uiColor: .systemRed)
    case "Left":
        return .init(symbol: "arrow.turn.up.left", text: nil, color: .purple, uiColor: .systemPurple)
    case "Right":
        return .init(symbol: "arrow.turn.up.right", text: nil, color: .purple, uiColor: .systemPurple)
    case "Straight":
        return .init(symbol: "arrow.up", text: nil, color: .gray, uiColor: .systemGray)
    case "First Aid":
        return .init(symbol: "cross.fill", text: nil, color: .red, uiColor: .systemRed)
    case "1st Category":
        return .init(symbol: nil, text: "1", color: .yellow, uiColor: .systemYellow)
    case "2nd Category":
        return .init(symbol: nil, text: "2", color: .yellow, uiColor: .systemYellow)
    case "3rd Category":
        return .init(symbol: nil, text: "3", color: .yellow, uiColor: .systemYellow)
    case "4th Category":
        return .init(symbol: nil, text: "4", color: .yellow, uiColor: .systemYellow)
    case "Hors Category":
        return .init(symbol: nil, text: "HC", color: .red, uiColor: .systemRed)
    case "Sprint":
        return .init(symbol: "bolt.fill", text: nil, color: .yellow, uiColor: .systemYellow)
    default:
        return .init(symbol: "mappin", text: nil, color: .orange, uiColor: .systemOrange)
    }
}

func formatRouteDistance(_ km: Double) -> String {
    km < 1 ? String(format: "%.0f m", km * 1000) : String(format: "%.2f km", km)
}

func formatRouteElevation(_ meters: Double?) -> String {
    guard let meters else { return "-" }
    return String(format: "%.0f m", meters)
}

func formatRouteCount(_ count: Int) -> String {
    "\(count)개"
}

func normalizedTrackPoints(from raw: [RawRoutePoint]) -> [TrackPoint] {
    var result: [TrackPoint] = []
    var cumulativeKm = 0.0
    var previous: RawRoutePoint?

    for point in raw {
        if let previous {
            cumulativeKm += Geo.haversineKm(previous.lat, previous.lon, point.lat, point.lon)
        }
        result.append(TrackPoint(
            lat: point.lat,
            lon: point.lon,
            ele: point.ele,
            time: point.time,
            cumKm: cumulativeKm
        ))
        previous = point
    }

    return result
}

struct RawRoutePoint: Equatable {
    var lat: Double
    var lon: Double
    var ele: Double?
    var time: String?
}

/// TCX를 읽은 뒤에는 Time으로 계산해 둔 누적거리를 우선 사용한다.
/// 이전 파일처럼 누적거리가 없는 경우에만 좌표 최근접 지점으로 되돌아간다.
func cueTrackIndex(_ cue: CourseCuePoint, in trackPoints: [TrackPoint]) -> Int? {
    guard let first = trackPoints.first else { return nil }
    if cue.distanceMeters > 0 {
        return Geo.nearestIndex(trackPoints, distanceKm: cue.distanceMeters / 1_000)
    }
    let firstPointError = Geo.haversineKm(first.lat, first.lon, cue.lat, cue.lon)
    if cue.distanceMeters == 0, firstPointError <= 0.05 { return 0 }
    return Geo.nearestIndex(trackPoints, lat: cue.lat, lon: cue.lon)
}
