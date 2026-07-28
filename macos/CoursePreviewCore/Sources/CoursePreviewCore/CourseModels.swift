import CoreLocation
import Foundation

public struct LoadedCourse: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var title: String
    public var sourceURL: URL
    public var fileKind: RouteFileKind
    public var routePoints: [CourseRoutePoint]
    public var trackPoints: [TrackPoint]
    public var cuePoints: [CourseCuePoint]

    public init(
        id: UUID = UUID(),
        title: String,
        sourceURL: URL,
        fileKind: RouteFileKind,
        routePoints: [CourseRoutePoint],
        trackPoints: [TrackPoint],
        cuePoints: [CourseCuePoint]
    ) {
        self.id = id
        self.title = title
        self.sourceURL = sourceURL
        self.fileKind = fileKind
        self.routePoints = routePoints
        self.trackPoints = trackPoints
        self.cuePoints = cuePoints
    }

    public var totalDistanceKm: Double {
        trackPoints.last?.cumKm ?? 0
    }

    public var elevationStats: CourseElevationStats {
        CourseElevationStats(trackPoints: trackPoints)
    }

    public var sortedCuePoints: [CourseCuePoint] {
        cuePoints.sorted { $0.distanceMeters < $1.distanceMeters }
    }
}

public enum RouteFileKind: String, Sendable {
    case gpx = "GPX"
    case tcx = "TCX"
    case csb = "CSB"
}

public struct CourseRoutePoint: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var lat: Double
    public var lon: Double

    public init(id: UUID = UUID(), lat: Double, lon: Double) {
        self.id = id
        self.lat = lat
        self.lon = lon
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

public struct CourseCuePoint: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var lat: Double
    public var lon: Double
    public var name: String
    public var pointType: String
    public var notes: String
    public var distanceMeters: Double

    public init(
        id: UUID = UUID(),
        lat: Double,
        lon: Double,
        name: String,
        pointType: String,
        notes: String,
        distanceMeters: Double
    ) {
        self.id = id
        self.lat = lat
        self.lon = lon
        self.name = name
        self.pointType = pointType
        self.notes = notes
        self.distanceMeters = distanceMeters
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    public var displayName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? cuePointLabel(for: pointType)
            : name
    }

    public var distanceKm: Double {
        distanceMeters / 1_000
    }
}

public struct TrackPoint: Equatable, Sendable {
    public var lat: Double
    public var lon: Double
    public var ele: Double?
    public var time: String?
    public var cumKm: Double

    public init(lat: Double, lon: Double, ele: Double?, time: String?, cumKm: Double) {
        self.lat = lat
        self.lon = lon
        self.ele = ele
        self.time = time
        self.cumKm = cumKm
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

public struct CourseProfileSelection: Equatable, Sendable {
    public var trackIndex: Int
    public var lat: Double
    public var lon: Double
    public var distanceKm: Double
    public var elevationMeters: Double?

    public init(trackIndex: Int, point: TrackPoint) {
        self.trackIndex = trackIndex
        lat = point.lat
        lon = point.lon
        distanceKm = point.cumKm
        elevationMeters = point.ele
    }

    public init(
        trackIndex: Int,
        lat: Double,
        lon: Double,
        distanceKm: Double,
        elevationMeters: Double?
    ) {
        self.trackIndex = trackIndex
        self.lat = lat
        self.lon = lon
        self.distanceKm = distanceKm
        self.elevationMeters = elevationMeters
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    public func endpointKind(in course: LoadedCourse) -> CourseTrackEndpointKind? {
        let count = course.trackPoints.count
        guard count > 0 else { return nil }
        if trackIndex == 0 { return .start }
        if count > 1, trackIndex == count - 1 { return .end }
        return nil
    }
}

public enum CourseTrackEndpointKind: Sendable {
    case start
    case end

    public var title: String {
        switch self {
        case .start: return "시작점"
        case .end: return "종료점"
        }
    }
}

public enum Geo {
    private static let earthRadiusKm = 6371.0088

    public static func haversineKm(
        _ lat1: Double,
        _ lon1: Double,
        _ lat2: Double,
        _ lon2: Double
    ) -> Double {
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2)
            + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return earthRadiusKm * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    public static func nearestIndex(
        _ points: [TrackPoint],
        lat: Double?,
        lon: Double?
    ) -> Int? {
        guard let lat, let lon, !points.isEmpty else { return nil }
        var bestIndex: Int?
        var bestDistance = Double.infinity
        for index in points.indices {
            let distance = haversineKm(points[index].lat, points[index].lon, lat, lon)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    public static func nearestIndex(_ points: [TrackPoint], distanceKm: Double) -> Int? {
        guard !points.isEmpty, distanceKm.isFinite else { return nil }
        var bestIndex = 0
        var bestDistance = abs(points[0].cumKm - distanceKm)
        for index in points.indices.dropFirst() {
            let distance = abs(points[index].cumKm - distanceKm)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }
}

public struct CourseElevationStats: Equatable, Sendable {
    public var min: Double?
    public var max: Double?
    public var span: Double?
    public var ascent: Double?
    public var descent: Double?
    public var hasData: Bool

    public init(trackPoints points: [TrackPoint]) {
        let elevations = points.compactMap(\.ele)
        let minEle = elevations.min()
        let maxEle = elevations.max()
        min = minEle
        max = maxEle
        span = minEle.flatMap { low in maxEle.map { Swift.max(0, $0 - low) } }
        hasData = !elevations.isEmpty

        guard points.count > 1 else {
            ascent = nil
            descent = nil
            return
        }

        var up = 0.0
        var down = 0.0
        var hasPair = false
        for index in 1..<points.count {
            guard let previous = points[index - 1].ele,
                  let current = points[index].ele else {
                continue
            }
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

public struct RouteElevationProgressStats: Equatable, Sendable {
    public var ascentFromStart: Double
    public var descentFromStart: Double
    public var ascentToEnd: Double
    public var descentToEnd: Double
}

public struct RouteElevationProgress: Equatable, Sendable {
    private var cumulativeAscent: [Double]
    private var cumulativeDescent: [Double]
    private var elevationPairCounts: [Int]

    public init(trackPoints points: [TrackPoint]) {
        guard !points.isEmpty else {
            cumulativeAscent = []
            cumulativeDescent = []
            elevationPairCounts = []
            return
        }

        cumulativeAscent = Array(repeating: 0, count: points.count)
        cumulativeDescent = Array(repeating: 0, count: points.count)
        elevationPairCounts = Array(repeating: 0, count: points.count)

        guard points.count > 1 else { return }
        for index in 1..<points.count {
            cumulativeAscent[index] = cumulativeAscent[index - 1]
            cumulativeDescent[index] = cumulativeDescent[index - 1]
            elevationPairCounts[index] = elevationPairCounts[index - 1]

            guard let previous = points[index - 1].ele,
                  let current = points[index].ele else {
                continue
            }
            elevationPairCounts[index] += 1
            let delta = current - previous
            if delta > 0 {
                cumulativeAscent[index] += delta
            } else {
                cumulativeDescent[index] += -delta
            }
        }
    }

    public var hasElevationData: Bool {
        (elevationPairCounts.last ?? 0) > 0
    }

    public func stats(at index: Int?) -> RouteElevationProgressStats? {
        guard hasElevationData, let index, !cumulativeAscent.isEmpty else { return nil }
        let clamped = min(max(index, 0), cumulativeAscent.count - 1)
        let totalAscent = cumulativeAscent.last ?? 0
        let totalDescent = cumulativeDescent.last ?? 0
        return makeStats(
            ascentFromStart: cumulativeAscent[clamped],
            descentFromStart: cumulativeDescent[clamped],
            totalAscent: totalAscent,
            totalDescent: totalDescent
        )
    }

    public func stats(
        atDistanceKm distanceKm: Double,
        trackPoints points: [TrackPoint]
    ) -> RouteElevationProgressStats? {
        guard hasElevationData,
              points.count == cumulativeAscent.count,
              !points.isEmpty else {
            return nil
        }
        guard points.count > 1 else { return stats(at: 0) }

        let totalAscent = cumulativeAscent.last ?? 0
        let totalDescent = cumulativeDescent.last ?? 0
        let firstKm = points[0].cumKm
        let lastKm = points[points.count - 1].cumKm
        let clampedKm = min(max(distanceKm, firstKm), lastKm)

        if clampedKm <= firstKm {
            return makeStats(
                ascentFromStart: cumulativeAscent[0],
                descentFromStart: cumulativeDescent[0],
                totalAscent: totalAscent,
                totalDescent: totalDescent
            )
        }

        for index in 1..<points.count where clampedKm <= points[index].cumKm {
            let previousKm = points[index - 1].cumKm
            let currentKm = points[index].cumKm
            let ratio = currentKm > previousKm
                ? min(max((clampedKm - previousKm) / (currentKm - previousKm), 0), 1)
                : 0
            let ascentFromStart = cumulativeAscent[index - 1]
                + (cumulativeAscent[index] - cumulativeAscent[index - 1]) * ratio
            let descentFromStart = cumulativeDescent[index - 1]
                + (cumulativeDescent[index] - cumulativeDescent[index - 1]) * ratio

            return makeStats(
                ascentFromStart: ascentFromStart,
                descentFromStart: descentFromStart,
                totalAscent: totalAscent,
                totalDescent: totalDescent
            )
        }

        return makeStats(
            ascentFromStart: totalAscent,
            descentFromStart: totalDescent,
            totalAscent: totalAscent,
            totalDescent: totalDescent
        )
    }

    private func makeStats(
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

public let cuePointTypes: [(value: String, label: String)] = [
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

public func cuePointLabel(for value: String) -> String {
    cuePointTypes.first { $0.value == value }?.label ?? "알 수 없음(\(value))"
}

public func formatRouteDistance(_ km: Double) -> String {
    km < 1 ? String(format: "%.0f m", km * 1_000) : String(format: "%.2f km", km)
}

public func formatRouteElevation(_ meters: Double?) -> String {
    guard let meters else { return "-" }
    return String(format: "%.0f m", meters)
}

public func formatRouteCount(_ count: Int) -> String {
    "\(count)개"
}

struct RawRoutePoint: Equatable {
    var lat: Double
    var lon: Double
    var ele: Double?
    var time: String?
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

public func cueTrackIndex(_ cue: CourseCuePoint, in trackPoints: [TrackPoint]) -> Int? {
    guard let first = trackPoints.first else { return nil }
    if cue.distanceMeters > 0 {
        return Geo.nearestIndex(trackPoints, distanceKm: cue.distanceMeters / 1_000)
    }
    let firstPointError = Geo.haversineKm(first.lat, first.lon, cue.lat, cue.lon)
    if cue.distanceMeters == 0, firstPointError <= 0.05 { return 0 }
    return Geo.nearestIndex(trackPoints, lat: cue.lat, lon: cue.lon)
}
