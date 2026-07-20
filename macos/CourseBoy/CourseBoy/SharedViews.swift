import SwiftUI
import AppKit
import MapKit
import CourseBoyKit

// MARK: - 지도 좌표계 최근접 투영

/// 지도 위 화면 좌표(`screenPoint`)에서 트랙 폴리라인에 가장 가까운 점을 찾아
/// 세그먼트 시작 인덱스, 세그먼트 내 비율(0..1), 화면 거리(pt)를 리턴한다.
func nearestProjectionOnMap(
    _ map: MKMapView,
    pts: [TrackPoint],
    to screenPoint: CGPoint
) -> (segmentStartIndex: Int, fraction: Double, screenDistance: CGFloat)? {
    guard pts.count >= 2 else { return nil }
    var best: (segmentStartIndex: Int, fraction: Double, screenDistance: CGFloat)?

    for i in 0..<(pts.count - 1) {
        let a = pts[i]
        let b = pts[i + 1]
        let p1 = map.convert(CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon), toPointTo: map)
        let p2 = map.convert(CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon), toPointTo: map)

        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0 else { continue }

        let rawT = ((screenPoint.x - p1.x) * dx + (screenPoint.y - p1.y) * dy) / len2
        let t = min(max(rawT, 0), 1)
        let projected = CGPoint(x: p1.x + dx * t, y: p1.y + dy * t)
        let distance = hypot(screenPoint.x - projected.x, screenPoint.y - projected.y)

        if best == nil || distance < best!.screenDistance {
            best = (i, Double(t), distance)
        }
    }

    return best
}

// MARK: - 지도 마커 이미지 (Hover / Pinned)

func makeHoverDotImage() -> NSImage {
    let size = NSSize(width: 12, height: 12)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.black.withAlphaComponent(0.28).setFill()
    NSBezierPath(ovalIn: NSRect(x: 1, y: 0, width: 10, height: 10)).fill()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 8, height: 8)).fill()
    NSColor.systemOrange.setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 8, height: 8))
    ring.lineWidth = 1
    ring.stroke()
    image.unlockFocus()
    return image
}

func makePinnedDotImage() -> NSImage {
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor.black.withAlphaComponent(0.32).setFill()
    NSBezierPath(ovalIn: NSRect(x: 1, y: 0, width: 16, height: 16)).fill()
    NSColor.systemYellow.withAlphaComponent(0.35).setFill()
    NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 16, height: 16)).fill()
    NSColor.systemYellow.setFill()
    NSBezierPath(ovalIn: NSRect(x: 5, y: 5, width: 8, height: 8)).fill()
    NSColor.black.withAlphaComponent(0.75).setStroke()
    let ring = NSBezierPath(ovalIn: NSRect(x: 5, y: 5, width: 8, height: 8))
    ring.lineWidth = 1.3
    ring.stroke()
    image.unlockFocus()
    return image
}

// MARK: - 공통 헬퍼

/// 큐시트 위치는 좌표보다 저장된 코스 누적거리를 우선한다.
/// 왕복 경로에서 같은 좌표가 여러 번 나와도 올바른 통과 지점을 유지한다.
func cueTrackIndex(_ cue: CourseCuePoint, in trackPoints: [TrackPoint]) -> Int? {
    guard let first = trackPoints.first else { return nil }
    if cue.distanceMeters > 0 {
        return Geo.nearestIndex(trackPoints, distanceKm: cue.distanceMeters / 1_000)
    }

    // 이전 CSB처럼 누적거리가 없던 데이터는 좌표를 호환 경로로 사용한다.
    let firstPointError = Geo.haversineKm(first.lat, first.lon, cue.lat, cue.lon)
    if cue.distanceMeters == 0, firstPointError <= 0.05 { return 0 }
    return Geo.nearestIndex(trackPoints, lat: cue.lat, lon: cue.lon)
}

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

// MARK: - Inspector Controls

struct InspectorToggleButton: View {
    @Binding var isPresented: Bool

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Label("인스펙터", systemImage: "sidebar.trailing")
                .symbolVariant(isPresented ? .fill : .none)
        }
        .help(isPresented ? "우측 패널 숨기기" : "우측 패널 보기")
        .keyboardShortcut("0", modifiers: [.command, .option])
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
    let firstKm = trackPoints.first!.cumKm
    let lastKm = trackPoints.last!.cumKm
    let clampedKm = min(max(km, firstKm), lastKm)

    // trackPoints 는 cumKm 오름차순이므로 binary search 로 구간을 찾는다.
    // 예전에는 hover 이벤트마다 O(n) 선형 탐색이라 5k+ 포인트에서 CPU 를
    // 태웠다.
    var lo = 0
    var hi = trackPoints.count - 1
    while lo + 1 < hi {
        let mid = (lo + hi) / 2
        if trackPoints[mid].cumKm <= clampedKm {
            lo = mid
        } else {
            hi = mid
        }
    }
    let a = trackPoints[lo]
    let b = trackPoints[hi]
    let span = b.cumKm - a.cumKm
    let fraction = span == 0 ? 0 : (clampedKm - a.cumKm) / span
    return routeHoverInfo(trackPoints: trackPoints, segmentStartIndex: lo, fraction: fraction)
}

func formatRouteDistance(_ km: Double) -> String {
    km < 1 ? String(format: "%.0f m", km * 1000) : String(format: "%.2f km", km)
}

// MARK: - 구간 선택

/// 고도 그래프나 큐시트에서 선택한 누적 거리 구간(km).
/// `startKm` ≤ `endKm` 으로 정규화해 사용한다.
struct ChartRangeSelection: Equatable, Sendable {
    var startKm: Double
    var endKm: Double
    /// 사용자가 드래그를 끝냈는지 여부. 드래그 중에는 false.
    var isDragging: Bool

    var lowerKm: Double { min(startKm, endKm) }
    var upperKm: Double { max(startKm, endKm) }
    var lengthKm: Double { upperKm - lowerKm }
}

/// 선택 구간의 통계 (거리/고도/경사).
struct RouteRangeStats: Equatable {
    var startKm: Double
    var endKm: Double
    var lengthKm: Double
    var startEle: Double?
    var endEle: Double?
    var minEle: Double?
    var maxEle: Double?
    var ascentMeters: Double
    var descentMeters: Double
    var averageGradePercent: Double?
}

struct RouteElevationProgressStats: Equatable {
    var ascentFromStart: Double
    var descentFromStart: Double
    var ascentToEnd: Double
    var descentToEnd: Double
}

/// 트랙 전체의 상승/하강 누적값을 한 번 계산해 임의 지점의 시작/잔여 고도를 빠르게 조회한다.
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
        for i in 1..<pts.count {
            cumulativeAscent[i] = cumulativeAscent[i - 1]
            cumulativeDescent[i] = cumulativeDescent[i - 1]
            elevationPairCounts[i] = elevationPairCounts[i - 1]

            guard let prevEle = pts[i - 1].ele, let currEle = pts[i].ele else { continue }
            elevationPairCounts[i] += 1
            let diff = currEle - prevEle
            if diff > 0 {
                cumulativeAscent[i] += diff
            } else {
                cumulativeDescent[i] += -diff
            }
        }
    }

    var hasElevationData: Bool {
        (elevationPairCounts.last ?? 0) > 0
    }

    func stats(at index: Int?) -> RouteElevationProgressStats? {
        guard hasElevationData, let index, !cumulativeAscent.isEmpty else { return nil }
        let i = min(max(index, 0), cumulativeAscent.count - 1)
        let totalAscent = cumulativeAscent.last ?? 0
        let totalDescent = cumulativeDescent.last ?? 0
        return RouteElevationProgressStats(
            ascentFromStart: cumulativeAscent[i],
            descentFromStart: cumulativeDescent[i],
            ascentToEnd: max(0, totalAscent - cumulativeAscent[i]),
            descentToEnd: max(0, totalDescent - cumulativeDescent[i])
        )
    }
}

func routeRangeStats(trackPoints pts: [TrackPoint], range: ChartRangeSelection) -> RouteRangeStats? {
    guard pts.count >= 2 else { return nil }
    let lo = range.lowerKm
    let hi = range.upperKm
    guard hi > lo else { return nil }

    let startInfo = routeHoverInfo(trackPoints: pts, nearestToDistanceKm: lo)
    let endInfo = routeHoverInfo(trackPoints: pts, nearestToDistanceKm: hi)
    let startEle = startInfo?.elevationMeters
    let endEle = endInfo?.elevationMeters

    var minEle: Double? = startEle
    var maxEle: Double? = startEle
    var ascent: Double = 0
    var descent: Double = 0

    var prevEle: Double? = startEle
    if let s = startEle {
        minEle = s
        maxEle = s
    }

    for tp in pts where tp.cumKm >= lo && tp.cumKm <= hi {
        if let e = tp.ele {
            if let mn = minEle { minEle = min(mn, e) } else { minEle = e }
            if let mx = maxEle { maxEle = max(mx, e) } else { maxEle = e }
            if let p = prevEle {
                let d = e - p
                if d > 0 { ascent += d } else { descent += -d }
            }
            prevEle = e
        }
    }
    if let e = endEle {
        if let mn = minEle { minEle = min(mn, e) } else { minEle = e }
        if let mx = maxEle { maxEle = max(mx, e) } else { maxEle = e }
        if let p = prevEle {
            let d = e - p
            if d > 0 { ascent += d } else { descent += -d }
        }
    }

    let length = hi - lo
    let avgGrade: Double? = {
        guard let s = startEle, let e = endEle, length > 0 else { return nil }
        return (e - s) / (length * 1000) * 100
    }()

    return RouteRangeStats(
        startKm: lo,
        endKm: hi,
        lengthKm: length,
        startEle: startEle,
        endEle: endEle,
        minEle: minEle,
        maxEle: maxEle,
        ascentMeters: ascent,
        descentMeters: descent,
        averageGradePercent: avgGrade
    )
}

/// 트랙포인트에서 누적 거리(km)에 해당하는 좌표를 보간으로 계산.
func interpolateTrackPoint(in pts: [TrackPoint], atDistanceKm km: Double) -> (lat: Double, lon: Double, ele: Double?)? {
    guard let info = routeHoverInfo(trackPoints: pts, nearestToDistanceKm: km) else { return nil }
    return (info.lat, info.lon, info.elevationMeters)
}

/// 드래그 구간에 해당하는 트랙포인트 부분 배열(시작/끝은 보간점 포함).
func trackPointsInRange(_ pts: [TrackPoint], range: ChartRangeSelection) -> [TrackPoint] {
    guard pts.count >= 2 else { return [] }
    let lo = range.lowerKm
    let hi = range.upperKm
    guard hi > lo else { return [] }

    var result: [TrackPoint] = []
    if let s = interpolateTrackPoint(in: pts, atDistanceKm: lo) {
        result.append(TrackPoint(lat: s.lat, lon: s.lon, ele: s.ele, time: nil, cumKm: lo))
    }
    for tp in pts where tp.cumKm > lo && tp.cumKm < hi {
        result.append(tp)
    }
    if let e = interpolateTrackPoint(in: pts, atDistanceKm: hi) {
        result.append(TrackPoint(lat: e.lat, lon: e.lon, ele: e.ele, time: nil, cumKm: hi))
    }
    return result
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
