import SwiftUI
import StravaTCXKit

// MARK: - 공통 헬퍼

func categoryLabel(_ cat: String?) -> String {
    guard let cat else { return "—" }
    return cat == "HC" ? "HC" : "Cat \(cat)"
}

func trackPoints(for segment: SegmentInfo) -> [TrackPoint] {
    guard let coords = segment.coordinates, !coords.isEmpty else { return [] }
    let elevs = segment.elevations
    let dists = segment.distances
    return coords.enumerated().map { i, c in
        let lat  = c.count >= 1 ? c[0] : 0
        let lon  = c.count >= 2 ? c[1] : 0
        let ele  = (elevs != nil && i < elevs!.count) ? elevs![i] : nil
        let cumKm = (dists != nil && i < dists!.count) ? dists![i] / 1000.0 : 0
        return TrackPoint(lat: lat, lon: lon, ele: ele, time: nil, cumKm: cumKm)
    }
}

// MARK: - 경로 hover 정보

struct RouteHoverInfo: Equatable, Sendable {
    var trackIndex: Int
    var lat: Double
    var lon: Double
    var distanceKm: Double
    var elevationMeters: Double?
    var gradePercent: Double?
    var directionDegrees: Double
    var directionLabel: String
}

func routeHoverInfo(
    trackPoints: [TrackPoint],
    segmentStartIndex: Int,
    fraction: Double
) -> RouteHoverInfo? {
    guard trackPoints.count >= 2 else { return nil }
    let startIndex = min(max(segmentStartIndex, 0), trackPoints.count - 2)
    let endIndex = startIndex + 1
    let a = trackPoints[startIndex]
    let b = trackPoints[endIndex]
    let t = min(max(fraction, 0), 1)
    let lat = a.lat + (b.lat - a.lat) * t
    let lon = a.lon + (b.lon - a.lon) * t
    let distanceKm = a.cumKm + (b.cumKm - a.cumKm) * t
    let elevation: Double?
    if let ae = a.ele, let be = b.ele {
        elevation = ae + (be - ae) * t
    } else {
        elevation = a.ele ?? b.ele
    }
    let grade: Double?
    if let ae = a.ele, let be = b.ele {
        let distanceMeters = abs(b.cumKm - a.cumKm) * 1000
        grade = distanceMeters > 0 ? (be - ae) / distanceMeters * 100 : nil
    } else {
        grade = nil
    }
    let degrees = bearingDegrees(from: a, to: b)
    return RouteHoverInfo(
        trackIndex: t < 0.5 ? startIndex : endIndex,
        lat: lat,
        lon: lon,
        distanceKm: distanceKm,
        elevationMeters: elevation,
        gradePercent: grade,
        directionDegrees: degrees,
        directionLabel: directionLabel(for: degrees)
    )
}

func routeHoverInfo(trackPoints: [TrackPoint], nearestToDistanceKm km: Double) -> RouteHoverInfo? {
    guard trackPoints.count >= 2 else { return nil }
    let clampedKm = min(max(km, trackPoints.first?.cumKm ?? 0), trackPoints.last?.cumKm ?? km)
    for i in 0..<(trackPoints.count - 1) {
        let a = trackPoints[i]
        let b = trackPoints[i + 1]
        let lo = min(a.cumKm, b.cumKm)
        let hi = max(a.cumKm, b.cumKm)
        if clampedKm >= lo, clampedKm <= hi {
            let span = b.cumKm - a.cumKm
            let fraction = span == 0 ? 0 : (clampedKm - a.cumKm) / span
            return routeHoverInfo(trackPoints: trackPoints, segmentStartIndex: i, fraction: fraction)
        }
    }
    return routeHoverInfo(trackPoints: trackPoints, segmentStartIndex: trackPoints.count - 2, fraction: 1)
}

func formatRouteDistance(_ km: Double) -> String {
    km < 1 ? String(format: "%.0f m", km * 1000) : String(format: "%.2f km", km)
}

func formatRouteElevation(_ meters: Double?) -> String {
    guard let meters else { return "—" }
    return String(format: "%.0f m", meters)
}

func formatRouteGrade(_ percent: Double?) -> String {
    guard let percent else { return "—" }
    return String(format: "%+.1f%%", percent)
}

func formatRouteDirection(_ info: RouteHoverInfo) -> String {
    "\(info.directionLabel) \(Int(info.directionDegrees.rounded()) % 360)°"
}

private func bearingDegrees(from a: TrackPoint, to b: TrackPoint) -> Double {
    let lat1 = a.lat * .pi / 180
    let lat2 = b.lat * .pi / 180
    let lonDelta = (b.lon - a.lon) * .pi / 180
    let y = sin(lonDelta) * cos(lat2)
    let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(lonDelta)
    return fmod(atan2(y, x) * 180 / .pi + 360, 360)
}

private func directionLabel(for degrees: Double) -> String {
    let labels = ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"]
    let index = Int((degrees + 22.5) / 45.0) % labels.count
    return labels[index]
}
