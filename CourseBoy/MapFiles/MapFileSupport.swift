import SwiftUI
import MapKit
import CourseBoyKit
import CourseBoyMapFile

// 사용자 지도 파일(Garmin IMG)을 macOS 화면에 붙이는 데 쓰는 것들.
// 파일 읽기·노면 분석·타일 그리기는 CourseBoyMapFile 패키지에 있고, 여기는 화면 쪽만 둔다.
// 동작은 모바일 앱과 같다(CourseBoyMobile/docs/map-surface-info.md).

extension MapFileError {
    var message: String {
        switch self {
        case .notGarminImage: return "Garmin IMG 지도 파일이 아닙니다."
        case .locked: return "기기에 잠긴 지도라 읽을 수 없습니다."
        case .unreadable: return "지도 파일을 읽지 못했습니다."
        case .alreadyAdded: return "이미 추가한 지도 파일입니다."
        }
    }
}

extension CourseSurfacePoint {
    init(_ point: TrackPoint) {
        self.init(lat: point.lat, lon: point.lon, cumKm: point.cumKm)
    }
}

/// 코스 화면이 그릴 노면 정보의 상태. 노면 소스를 고르지 않았으면 이 값 자체가 nil이다.
enum CourseSurfaceStatus: Equatable {
    case loading
    case ready(CourseSurfaceAnalysis)
    /// 지도 파일을 찾을 수 없거나 읽지 못했다.
    case unavailable

    var analysis: CourseSurfaceAnalysis? {
        if case .ready(let analysis) = self { return analysis }
        return nil
    }
}

/// 노면 분석을 다시 할지 가리는 값. 경로나 노면 소스가 바뀌면 달라진다.
struct CourseSurfaceTaskKey: Equatable {
    var sourceID: UUID?
    var sourceFingerprint: String?
    var count: Int
    var firstLat: Double
    var firstLon: Double
    var lastLat: Double
    var lastLon: Double
    var totalKm: Double

    @MainActor
    init(trackPoints: [TrackPoint]) {
        let store = MapFileStore.shared
        sourceID = store.surfaceSource?.id
        sourceFingerprint = store.surfaceSource?.fingerprint
        count = trackPoints.count
        firstLat = trackPoints.first?.lat ?? 0
        firstLon = trackPoints.first?.lon ?? 0
        lastLat = trackPoints.last?.lat ?? 0
        lastLon = trackPoints.last?.lon ?? 0
        totalKm = trackPoints.last?.cumKm ?? 0
    }
}

extension MapFileStore {
    /// 코스의 노면 상태를 구한다. 노면 소스가 없으면 nil.
    func surfaceStatus(for trackPoints: [TrackPoint]) async -> CourseSurfaceStatus? {
        guard surfaceSource != nil, trackPoints.count >= 2 else { return nil }
        switch await surfaceState(for: trackPoints.map(CourseSurfacePoint.init)) {
        case .ready(let analysis): return .ready(analysis)
        case .unavailable: return .unavailable
        case nil: return nil
        }
    }
}

// MARK: - 노면 표시

extension RoadSurface {
    var displayName: String {
        switch self {
        case .paved: return "포장"
        case .unpaved: return "비포장"
        case .unknown: return "정보 없음"
        }
    }

    /// 비율 막대의 색. 경로·섹션 색과 겹치지 않게 무채색과 흙색을 쓴다.
    var barColor: Color {
        switch self {
        case .paved: return Color(nsColor: .systemGray)
        case .unpaved: return Color(red: 0.72, green: 0.47, blue: 0.22)
        case .unknown: return Color(nsColor: .quaternaryLabelColor)
        }
    }
}

/// 포장·비포장·정보 없음의 비율을 한 줄 막대로 보여준다.
struct SurfaceShareBar: View {
    let analysis: CourseSurfaceAnalysis

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach([RoadSurface.paved, .unpaved, .unknown], id: \.self) { surface in
                    let share = analysis.totalKm > 0 ? analysis.distanceKm(of: surface) / analysis.totalKm : 0
                    if share > 0 {
                        surface.barColor
                            .frame(width: max(2, (proxy.size.width - 4) * share))
                    }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
        .accessibilityHidden(true)
    }
}

// MARK: - 경로 색

/// 지도에서 코스 선을 칠하는 방식. 모바일 앱의 경로 색상(CourseRouteColoring)과 같은 항목이다.
enum RouteColorMode: String, CaseIterable, Identifiable {
    /// 순간 경사도에 따라 칠한다.
    case grade
    /// 한 가지 색으로 칠하고 비포장 구간에 흰 점선을 긋는다. 노면 정보가 있을 때만 고를 수 있다.
    case surface
    /// 한 가지 색으로 칠한다.
    case solid
    /// 섹션마다 정한 색(기본).
    case section

    var id: String { rawValue }

    var label: String {
        switch self {
        case .grade: return "경사도"
        case .surface: return "노면"
        case .solid: return "단색"
        case .section: return "섹션 색"
        }
    }

    /// 메뉴에 내놓을 방식. 노면 정보가 없으면 노면 방식은 뺀다.
    static func options(hasSurface: Bool) -> [RouteColorMode] {
        hasSurface ? allCases : allCases.filter { $0 != .surface }
    }

    static let storageKey = "routeColor.main"
    /// 노면 방식의 코스 선 색. 비포장 구간의 흰 점선이 잘 보이도록 짙은 색을 쓴다.
    static let surfaceColor = NSColor(red: 0.25, green: 0.32, blue: 0.85, alpha: 1)
    /// 단색 방식의 코스 선 색. 모바일 앱의 단색과 같다.
    static let solidColor = NSColor(red: 0.88, green: 0.21, blue: 0.17, alpha: 1)

    /// 코스 선 두께.
    var lineWidth: CGFloat {
        switch self {
        case .surface: return 5
        case .grade: return 4
        case .solid, .section: return 3
        }
    }
}

/// 비포장 구간들. 코스 선 한가운데에 흰 점선을 그어 비포장임을 표시한다.
final class CourseUnpavedMultiPolyline: MKMultiPolyline {}

extension CourseUnpavedMultiPolyline {
    /// 비포장 구간을 선으로 만든다. 섹션 사이처럼 경로가 끊기는 곳에서는 선을 나눈다.
    /// - Parameter breakAfter: 이 번호의 점 다음에서 경로가 끊긴다.
    static func make(
        runs: [CourseSurfaceAnalysis.Run],
        trackPoints: [TrackPoint],
        breakAfter: Set<Int>
    ) -> CourseUnpavedMultiPolyline? {
        var lines: [MKPolyline] = []
        for run in runs where run.surface == .unpaved {
            guard run.startIndex >= 0, run.endIndex < trackPoints.count, run.startIndex < run.endIndex else { continue }
            var coordinates: [CLLocationCoordinate2D] = []
            for index in run.startIndex...run.endIndex {
                let point = trackPoints[index]
                coordinates.append(CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon))
                if breakAfter.contains(index) {
                    if coordinates.count >= 2 {
                        lines.append(MKPolyline(coordinates: coordinates, count: coordinates.count))
                    }
                    coordinates = []
                }
            }
            if coordinates.count >= 2 {
                lines.append(MKPolyline(coordinates: coordinates, count: coordinates.count))
            }
        }
        return lines.isEmpty ? nil : CourseUnpavedMultiPolyline(lines)
    }

    /// 코스 선(`routeWidth`) 한가운데의 흰 점선.
    static func renderer(for overlay: CourseUnpavedMultiPolyline, routeWidth: CGFloat) -> MKMultiPolylineRenderer {
        let renderer = MKMultiPolylineRenderer(multiPolyline: overlay)
        renderer.lineWidth = max(1.5, routeWidth * 0.36)
        renderer.lineCap = .butt
        renderer.lineJoin = .round
        renderer.lineDashPattern = [NSNumber(value: Double(routeWidth) * 0.9), NSNumber(value: Double(routeWidth) * 0.9)]
        renderer.strokeColor = .white
        return renderer
    }
}

// MARK: - 지도 위에 덮기

extension MKMapView {
    /// 사용자 지도 파일을 기본 지도 위, 코스 선 아래에 덮는다. 이미 덮은 것과 같으면 그대로 둔다.
    func syncMapFileOverlay(_ source: GarminTileSource?) {
        let current = overlays.compactMap { $0 as? GarminTileOverlay }
        if current.count == 1, current[0].source === source { return }
        if current.isEmpty, source == nil { return }
        removeOverlays(current)
        if let source {
            insertOverlay(GarminTileOverlay(source: source), at: 0, level: .aboveRoads)
        }
    }

    /// 사용자 지도 파일 오버레이를 뺀 오버레이. 경로를 다시 그릴 때 이것만 걷어 낸다.
    var routeOverlays: [MKOverlay] {
        overlays.filter { !($0 is GarminTileOverlay) }
    }
}

/// 지도 종류 메뉴의 '오버레이' 섹션. 기본 지도와 따로, 그 위에 덮을 지도 파일을 켜고 끈다.
/// '지도에서 보기'를 켠 파일이 없으면 보이지 않는다.
struct MapOverlayMenuSection: View {
    private var store: MapFileStore { .shared }

    var body: some View {
        if !store.displayableFiles.isEmpty {
            Section("오버레이") {
                ForEach(store.displayableFiles) { file in
                    // 한 번에 하나만 덮는다. 다른 것을 켜면 앞의 것은 꺼지고, 켠 것을 다시 누르면 꺼진다.
                    Toggle(isOn: Binding(
                        get: { store.displayMapID == file.id },
                        set: { store.displayMapID = $0 ? file.id : nil }
                    )) {
                        Text(file.name)
                    }
                }
            }
        }
    }
}
