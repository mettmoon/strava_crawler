import SwiftUI
import MapKit
import CourseBoyKit
import CourseBoyMapFile

final class HighlightPolyline: MKPolyline {}
final class RangeSelectionPolyline: MKPolyline {}
/// 코스 본선. `color`가 있으면(섹션 색) 그 색으로, 없으면 기본색으로 그린다.
final class MainRoutePolyline: MKPolyline {
    var color: NSColor?
}

final class RangeEndpointAnnotation: MKPointAnnotation {
    enum Kind { case start, end }
    let kind: Kind
    let distanceKm: Double
    let elevationMeters: Double?

    init(kind: Kind, lat: Double, lon: Double, distanceKm: Double, elevationMeters: Double?) {
        self.kind = kind
        self.distanceKm = distanceKm
        self.elevationMeters = elevationMeters
        super.init()
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        let label = "\(formatRouteDistance(distanceKm)) · \(formatRouteElevation(elevationMeters))"
        title = kind == .start ? "구간 시작" : "구간 종료"
        subtitle = label
    }
}

final class CueAnnotation: MKPointAnnotation {
    let cue: CourseCuePoint
    init(cue: CourseCuePoint) {
        self.cue = cue
        super.init()
        coordinate = CLLocationCoordinate2D(latitude: cue.lat, longitude: cue.lon)
        title = cue.name.isEmpty ? cuePointLabel(for: cue.pointType) : cue.name
    }
}

final class EndpointAnnotation: MKPointAnnotation {
    enum Kind {
        case start
        case end
    }

    let kind: Kind

    init(kind: Kind, point: TrackPoint) {
        self.kind = kind
        super.init()
        coordinate = CLLocationCoordinate2D(latitude: point.lat, longitude: point.lon)
        title = kind == .start ? "시작점" : "종료점"
    }
}

final class HoverAnnotation: MKPointAnnotation {}
final class PinnedLocationAnnotation: MKPointAnnotation {
    let distanceKm: Double
    let elevationMeters: Double?
    init(lat: Double, lon: Double, distanceKm: Double, elevationMeters: Double?) {
        self.distanceKm = distanceKm
        self.elevationMeters = elevationMeters
        super.init()
        coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        title = formatRouteDistance(distanceKm)
        subtitle = formatRouteElevation(elevationMeters)
    }
}

let rangeEndpointTopLayerZPosition: CGFloat = 1_000_000

func configureRangeEndpointAnnotationViewAsTopMost(_ view: MKAnnotationView) {
    view.clusteringIdentifier = nil
    view.displayPriority = .required
    view.canShowCallout = true
    view.zPriority = .max
    view.wantsLayer = true
    view.layer?.zPosition = rangeEndpointTopLayerZPosition
}

/// 좌표가 지도 가시 영역(가장자리 여백 포함) 밖이면 줌 레벨은 유지한 채
/// 해당 좌표가 중앙에 오도록 카메라를 이동한다. 이미 보이면 아무것도 하지 않는다.
func revealCoordinateIfNeeded(_ coordinate: CLLocationCoordinate2D, in map: MKMapView) {
    let visible = map.visibleMapRect
    guard !visible.isNull, visible.size.width > 0, visible.size.height > 0 else { return }
    let safeRect = visible.insetBy(dx: visible.size.width * 0.08, dy: visible.size.height * 0.08)
    guard !safeRect.contains(MKMapPoint(coordinate)) else { return }
    map.setCenter(coordinate, animated: true)
}

func promoteRangeEndpointAnnotationViews(in map: MKMapView) {
    let promote = {
        for annotation in map.annotations where annotation is RangeEndpointAnnotation {
            guard let view = map.view(for: annotation) else { continue }
            configureRangeEndpointAnnotationViewAsTopMost(view)
            view.superview?.addSubview(view, positioned: .above, relativeTo: nil)
        }
    }
    promote()
    DispatchQueue.main.async(execute: promote)
}

/// 선택 구간 등 지정한 영역이 지도에 꽉 차도록 카메라를 애니메이션으로 이동한다.
/// 너무 작은 영역(직선 구간 등)은 최소 크기로 넓혀서 과도하게 확대되지 않게 한다.
func fitMapCamera(_ map: MKMapView, to rect: MKMapRect, minimumMeters: Double = 300) {
    guard !rect.isNull else { return }
    let center = MKMapPoint(x: rect.midX, y: rect.midY)
    let minSize = minimumMeters * MKMapPointsPerMeterAtLatitude(center.coordinate.latitude)
    let width = max(rect.width, minSize)
    let height = max(rect.height, minSize)
    let target = MKMapRect(
        x: center.x - width / 2,
        y: center.y - height / 2,
        width: width,
        height: height
    )
    let padding = NSEdgeInsets(top: 48, left: 48, bottom: 48, right: 48)
    if map.frame.size == .zero {
        DispatchQueue.main.async {
            map.setVisibleMapRect(target, edgePadding: padding, animated: false)
        }
    } else {
        map.setVisibleMapRect(target, edgePadding: padding, animated: true)
    }
}

final class HoverMapView: MKMapView {
    var onRouteMouseMoved: ((HoverMapView, CGPoint) -> Void)?
    var onRouteMouseExited: ((HoverMapView) -> Void)?
    private var routeTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        if let routeTrackingArea {
            removeTrackingArea(routeTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        routeTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        onRouteMouseMoved?(self, convert(event.locationInWindow, from: nil))
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        onRouteMouseExited?(self)
        super.mouseExited(with: event)
    }
}

/// 경로 위 지점의 방향·거리·고도·경사를 지도 위에 띄우는 말풍선. 보기·편집 지도가 함께 쓴다.
final class RouteHoverTooltip {
    private weak var bubble: NSVisualEffectView?
    private weak var label: NSTextField?

    /// 지도 좌표계의 `point` 옆에 말풍선을 띄운다. 지도 가장자리를 넘지 않도록 자리를 옮긴다.
    func show(in map: MKMapView, at point: CGPoint, info: RouteHoverInfo) {
        let (bubble, label) = ensure(in: map)
        label.stringValue = """
        방향 \(formatRouteDirection(info))
        거리 \(formatRouteDistance(info.distanceKm))
        고도 \(formatRouteElevation(info.elevationMeters))
        경사 \(formatRouteGrade(info.gradePercent))
        """

        let maxTextSize = CGSize(width: 180, height: 100)
        let textSize = label.attributedStringValue.boundingRect(
            with: maxTextSize,
            options: [.usesLineFragmentOrigin]
        ).size
        let width = min(max(126, ceil(textSize.width) + 18), 198)
        let height = ceil(textSize.height) + 14

        var origin = CGPoint(x: point.x + 14, y: point.y + 14)
        if origin.x + width > map.bounds.maxX - 8 {
            origin.x = point.x - width - 14
        }
        if origin.y + height > map.bounds.maxY - 8 {
            origin.y = point.y - height - 14
        }
        origin.x = min(max(origin.x, map.bounds.minX + 8), map.bounds.maxX - width - 8)
        origin.y = min(max(origin.y, map.bounds.minY + 8), map.bounds.maxY - height - 8)

        bubble.frame = CGRect(x: origin.x, y: origin.y, width: width, height: height)
        bubble.isHidden = false
    }

    /// 경로 위 지점 자체에 말풍선을 띄운다(고도 그래프 hover 등 지도 밖에서 위치가 정해질 때).
    func show(in map: MKMapView, atRoutePointOf info: RouteHoverInfo) {
        let point = map.convert(
            CLLocationCoordinate2D(latitude: info.lat, longitude: info.lon),
            toPointTo: map
        )
        show(in: map, at: point, info: info)
    }

    func hide() {
        bubble?.isHidden = true
    }

    func remove() {
        bubble?.removeFromSuperview()
        bubble = nil
        label = nil
    }

    private func ensure(in map: MKMapView) -> (NSVisualEffectView, NSTextField) {
        if let bubble, let label, bubble.superview === map {
            return (bubble, label)
        }
        remove()

        let bubble = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: 150, height: 60))
        bubble.material = .hudWindow
        bubble.blendingMode = .withinWindow
        bubble.state = .active
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 6
        bubble.layer?.borderWidth = 1
        bubble.layer?.borderColor = NSColor.separatorColor.cgColor
        bubble.isHidden = true

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 4
        label.lineBreakMode = .byClipping

        bubble.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -7),
        ])

        map.addSubview(bubble)
        self.bubble = bubble
        self.label = label
        return (bubble, label)
    }
}

struct RouteMapView: View {
    let trackPoints: [TrackPoint]
    /// 비어 있지 않으면 지도 polyline을 섹션 경계에서 끊어 그린다.
    var sectionTrackPoints: [[TrackPoint]] = []
    /// `sectionTrackPoints`와 같은 순서의 섹션 색(hex). 비어 있으면 기본색 한 가지로 그린다.
    var sectionColorHexes: [String?] = []
    var highlightPoints: [TrackPoint] = []
    var cuePoints: [CourseCuePoint] = []
    var focusedCueID: UUID? = nil
    /// 빈 영역(어떤 annotation도 아닌 곳) 클릭 시 호출. 큐 포커스 해제 등에 사용.
    var onDeselectFocus: (() -> Void)? = nil
    /// 사용자가 지도의 cue 핀을 직접 탭했을 때 호출. 인스펙터/그래프 선택 동기화에 사용.
    var onSelectCue: ((UUID) -> Void)? = nil
    @Binding var hoverInfo: RouteHoverInfo?
    /// 선택한 거리 구간을 지도에도 강조 표시.
    var rangeSelection: ChartRangeSelection? = nil
    /// 그래프 클릭으로 지정된 임시 pin 위치(km).
    var pinnedDistanceKm: Double? = nil
    /// 지도에서 경로 위 클릭 시 호출. 인자: 누적 거리(km).
    var onPinDistance: ((Double) -> Void)? = nil
    /// true면 구간 선택이 확정될 때 선택 구간으로 카메라를 확대 이동한다.
    var zoomsToRangeSelection: Bool = false
    /// 값이 바뀔 때마다 카메라를 경로 전체 보기로 되돌린다.
    var zoomResetToken: Int = 0
    /// `trackPoints` 기준의 노면 분석. 있으면 지도 메뉴에서 경로 색을 `노면`으로 고를 수 있다.
    var surfaceAnalysis: CourseSurfaceAnalysis? = nil
    /// 지도 메뉴에서 경로 색을 고를 수 있게 할지.
    var showsRouteColorMenu: Bool = true

    @AppStorage(MapStyleStorageKey.main) private var mapStyleRaw: String = MapStyleOption.standard.rawValue
    @AppStorage(RouteColorMode.storageKey) private var routeColorRaw: String = RouteColorMode.section.rawValue

    private var routeColor: Binding<RouteColorMode> {
        Binding(
            get: { RouteColorMode(rawValue: routeColorRaw) ?? .section },
            set: { routeColorRaw = $0.rawValue }
        )
    }

    /// 실제로 칠할 방식. 노면을 골랐어도 이 코스에 노면 정보가 없으면 섹션 색으로 칠한다.
    private var effectiveRouteColor: RouteColorMode {
        let mode = routeColor.wrappedValue
        return mode == .surface && surfaceAnalysis == nil ? .section : mode
    }

    /// 노면 방식으로 그릴 때의 구간. 노면 정보가 없거나 다른 방식이면 nil.
    private var surfaceRuns: [CourseSurfaceAnalysis.Run]? {
        guard let surfaceAnalysis, effectiveRouteColor == .surface else { return nil }
        return surfaceAnalysis.runs
    }

    private var mapStyle: Binding<MapStyleOption> {
        Binding(
            get: { MapStyleOption(rawValue: mapStyleRaw) ?? .standard },
            set: { mapStyleRaw = $0.rawValue }
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RouteMapRepresentable(
                trackPoints: trackPoints,
                sectionTrackPoints: sectionTrackPoints,
                sectionColorHexes: sectionColorHexes,
                highlightPoints: highlightPoints,
                cuePoints: cuePoints,
                focusedCueID: focusedCueID,
                onDeselectFocus: onDeselectFocus,
                onSelectCue: onSelectCue,
                onPinDistance: onPinDistance,
                hoverInfo: $hoverInfo,
                rangeSelection: rangeSelection,
                pinnedDistanceKm: pinnedDistanceKm,
                zoomsToRangeSelection: zoomsToRangeSelection,
                zoomResetToken: zoomResetToken,
                mapStyle: mapStyle.wrappedValue,
                tileSource: MapFileStore.shared.displayTileSource,
                routeColorMode: effectiveRouteColor,
                surfaceRuns: surfaceRuns
            )
            MapStylePicker(
                selection: mapStyle,
                routeColor: showsRouteColorMenu ? routeColor : nil,
                routeColorOptions: RouteColorMode.options(hasSurface: surfaceAnalysis != nil)
            )
                .padding(8)
        }
    }
}

private struct RouteMapRepresentable: NSViewRepresentable {
    let trackPoints: [TrackPoint]
    var sectionTrackPoints: [[TrackPoint]] = []
    var sectionColorHexes: [String?] = []
    var highlightPoints: [TrackPoint] = []
    var cuePoints: [CourseCuePoint] = []
    var focusedCueID: UUID? = nil
    var onDeselectFocus: (() -> Void)? = nil
    var onSelectCue: ((UUID) -> Void)? = nil
    var onPinDistance: ((Double) -> Void)? = nil
    @Binding var hoverInfo: RouteHoverInfo?
    var rangeSelection: ChartRangeSelection? = nil
    var pinnedDistanceKm: Double? = nil
    var zoomsToRangeSelection: Bool = false
    var zoomResetToken: Int = 0
    var mapStyle: MapStyleOption
    /// 기본 지도 위에 덮을 사용자 지도 파일.
    var tileSource: GarminTileSource? = nil
    /// 코스 선을 칠하는 방식.
    var routeColorMode: RouteColorMode = .section
    /// 노면 방식일 때의 노면 구간. 비포장 구간에 점선을 긋는다.
    var surfaceRuns: [CourseSurfaceAnalysis.Run]? = nil

    private var appliedStyle: AppliedMapStyle {
        AppliedMapStyle(style: mapStyle, flat: tileSource != nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func trackSignature(for pts: [TrackPoint]) -> String {
        guard let first = pts.first, let last = pts.last else { return "" }
        return String(
            format: "%d|%.6f|%.6f|%.6f|%.6f|%.6f",
            pts.count, first.lat, first.lon, last.lat, last.lon, last.cumKm
        )
    }

    private var effectiveTracks: [[TrackPoint]] {
        let nonEmpty = sectionTrackPoints.filter { !$0.isEmpty }
        return nonEmpty.isEmpty ? (trackPoints.isEmpty ? [] : [trackPoints]) : nonEmpty
    }

    /// `effectiveTracks`와 같은 순서의 섹션 색. 섹션 색 정보가 없으면 빈 배열.
    private var effectiveColorHexes: [String?] {
        guard sectionColorHexes.count == sectionTrackPoints.count else { return [] }
        let pairs = zip(sectionTrackPoints, sectionColorHexes).filter { !$0.0.isEmpty }
        return pairs.map(\.1)
    }

    static func dismantleNSView(_ map: MKMapView, coordinator: Coordinator) {
        // NSClickGestureRecognizer 는 target(Coordinator) 를 강참조한다.
        // 델리게이트와 콜백을 끊지 않으면 Coordinator/맵이 함께 살아남는다.
        for gr in Array(map.gestureRecognizers) {
            map.removeGestureRecognizer(gr)
        }
        map.delegate = nil
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        if let hover = map as? HoverMapView {
            hover.onRouteMouseMoved = nil
            hover.onRouteMouseExited = nil
        }
        coordinator.mainPolylines = []
        coordinator.highlightPolyline = nil
        coordinator.rangePolylines = []
        coordinator.endpointAnnotations = []
        coordinator.cueAnnotations = []
        coordinator.rangeEndpointAnnotations = []
        coordinator.hoverAnnotation = nil
        coordinator.pinnedAnnotation = nil
        coordinator.onDeselectFocus = nil
        coordinator.onSelectCue = nil
        coordinator.onPinDistance = nil
        coordinator.hoverInfo = nil
        coordinator.removeTooltip()
    }

    func makeNSView(context: Context) -> MKMapView {
        let map = HoverMapView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        let coordinator = context.coordinator
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        applyMapStyle(mapStyle, to: map, flat: appliedStyle.flat)
        coordinator.appliedMapStyle = appliedStyle
        map.onRouteMouseMoved = { [weak coordinator] map, point in
            coordinator?.handleMouseMoved(in: map, point: point)
        }
        map.onRouteMouseExited = { [weak coordinator] map in
            coordinator?.clearHover(in: map)
        }

        let leftClick = NSClickGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleEmptyAreaClick(_:))
        )
        leftClick.buttonMask = 1
        leftClick.numberOfClicksRequired = 1
        leftClick.delaysPrimaryMouseButtonEvents = false
        map.addGestureRecognizer(leftClick)

        let rightClick = NSClickGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleRightClick(_:))
        )
        rightClick.buttonMask = 2
        rightClick.numberOfClicksRequired = 1
        map.addGestureRecognizer(rightClick)

        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.appliedMapStyle != appliedStyle {
            applyMapStyle(mapStyle, to: map, flat: appliedStyle.flat)
            coordinator.appliedMapStyle = appliedStyle
        }
        map.syncMapFileOverlay(tileSource)
        // 렌더러를 만들기 전에 정해 둔다. 방식이 바뀌면 아래에서 경로를 다시 그린다.
        coordinator.routeLineWidth = routeColorMode.lineWidth
        // count + 총거리 + 첫/끝 좌표만으로 트랙 변경을 감지한다.
        // 이전에는 매번 트랙포인트 수만큼 문자열을 만들어 5k+ 포인트에서 큰
        // 할당 비용이 발생했다.
        let tracks = effectiveTracks
        let colorHexes = effectiveColorHexes
        let signature = tracks.map(trackSignature(for:)).joined(separator: "#")
            + "@" + colorHexes.map { $0 ?? "" }.joined(separator: ",")
            + "@" + routeColorMode.rawValue
        coordinator.trackPoints = trackPoints
        var pointOffset = 0
        coordinator.discontinuityAfterIndices = Set(tracks.dropLast().map { points in
            pointOffset += points.count
            return pointOffset - 1
        })
        coordinator.hoverInfo = $hoverInfo
        coordinator.onDeselectFocus = onDeselectFocus
        coordinator.onSelectCue = onSelectCue
        coordinator.onPinDistance = onPinDistance

        if coordinator.builtPointSignature != signature {
            // 사용자 지도 파일 오버레이는 경로와 상관없으므로 남겨 둔다.
            map.removeOverlays(map.routeOverlays)
            map.removeAnnotations(map.annotations)
            coordinator.mainPolylines = []
            coordinator.unpavedOverlay = nil
            coordinator.appliedUnpavedRuns = nil
            coordinator.builtPointSignature = signature
            coordinator.highlightSignature = []
            coordinator.highlightPolyline = nil
            coordinator.endpointAnnotations = []
            coordinator.cueAnnotations = []
            coordinator.hoverAnnotation = nil
            coordinator.rangePolylines = []
            coordinator.rangeEndpointAnnotations = []
            coordinator.lastRangeSignature = ""
            coordinator.pinnedAnnotation = nil
            coordinator.lastPinnedSignature = ""
            coordinator.hideTooltip()
            if hoverInfo != nil {
                let hoverBinding = $hoverInfo
                DispatchQueue.main.async {
                    hoverBinding.wrappedValue = nil
                }
            }

            let drawableTracks = tracks.filter { $0.count >= 2 }
            let drawableColorHexes: [String?] = colorHexes.count == tracks.count
                ? zip(tracks, colorHexes).filter { $0.0.count >= 2 }.map(\.1)
                : []
            guard !drawableTracks.isEmpty,
                  let firstPoint = tracks.first?.first,
                  let lastPoint = tracks.last?.last else { return }

            var polylines: [MKPolyline] = []
            var fitRect = MKMapRect.null
            // 섹션 순서대로 추가하므로 뒤쪽 섹션일수록 위에 그려진다(편집 화면과 같은 z-순서).
            for (index, points) in drawableTracks.enumerated() {
                let coords = points.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                if routeColorMode == .grade {
                    // 섹션마다 경사도 구간을 나눠, 구간마다 그 경사 색의 선을 긋는다.
                    for run in RouteGradeColoring.runs(for: points) {
                        let runCoords = Array(coords[run.startIndex...run.endIndex])
                        let polyline = MainRoutePolyline(coordinates: runCoords, count: runCoords.count)
                        polyline.color = run.band.color
                        polylines.append(polyline)
                    }
                    fitRect = fitRect.union(MKPolyline(coordinates: coords, count: coords.count).boundingMapRect)
                    continue
                }
                let polyline = MainRoutePolyline(coordinates: coords, count: coords.count)
                switch routeColorMode {
                case .surface:
                    polyline.color = RouteColorMode.surfaceColor
                case .solid:
                    polyline.color = RouteColorMode.solidColor
                case .section, .grade:
                    if index < drawableColorHexes.count {
                        polyline.color = SectionPalette.nsColor(drawableColorHexes[index])
                    }
                }
                polylines.append(polyline)
                fitRect = fitRect.union(polyline.boundingMapRect)
            }
            map.addOverlays(polylines, level: .aboveRoads)
            coordinator.mainPolylines = polylines
            let endpointAnnotations = [
                EndpointAnnotation(kind: .start, point: firstPoint),
                EndpointAnnotation(kind: .end, point: lastPoint),
            ]
            coordinator.endpointAnnotations = endpointAnnotations
            map.addAnnotations(endpointAnnotations)

            fitRect = fitRect.insetBy(
                dx: -fitRect.width * 0.1,
                dy: -fitRect.height * 0.1
            )
            if map.frame.size == .zero {
                DispatchQueue.main.async { map.setVisibleMapRect(fitRect, animated: false) }
            } else {
                map.setVisibleMapRect(fitRect, animated: false)
            }
        }

        syncUnpaved(map: map, coordinator: coordinator)
        updateHighlight(map: map, coordinator: coordinator)
        updateCuePoints(map: map, coordinator: coordinator)
        coordinator.syncFocusedCue(in: map, focusedID: focusedCueID)
        coordinator.syncHoverPresentation(in: map, info: hoverInfo)
        coordinator.syncRangeSelection(
            in: map,
            selection: rangeSelection,
            fitsCamera: zoomsToRangeSelection
        )
        coordinator.syncPinnedLocation(in: map, distanceKm: pinnedDistanceKm)
        if coordinator.appliedZoomResetToken != zoomResetToken {
            coordinator.appliedZoomResetToken = zoomResetToken
            let fullRect = coordinator.mainPolylines.reduce(MKMapRect.null) {
                $0.union($1.boundingMapRect)
            }
            if !fullRect.isNull {
                map.setVisibleMapRect(
                    fullRect.insetBy(dx: -fullRect.width * 0.1, dy: -fullRect.height * 0.1),
                    animated: true
                )
            }
        }
        promoteRangeEndpointAnnotationViews(in: map)
    }

    // MARK: - 비포장 점선

    /// 비포장 구간의 흰 점선을 코스 선 바로 위에 긋는다. 노면 방식이 아니면 걷어 낸다.
    private func syncUnpaved(map: MKMapView, coordinator: Coordinator) {
        let runs = surfaceRuns?.filter { $0.surface == .unpaved }
        guard runs != coordinator.appliedUnpavedRuns else { return }
        coordinator.appliedUnpavedRuns = runs
        if let old = coordinator.unpavedOverlay {
            map.removeOverlay(old)
            coordinator.unpavedOverlay = nil
        }
        guard let runs, !runs.isEmpty,
              let overlay = CourseUnpavedMultiPolyline.make(
                  runs: runs,
                  trackPoints: trackPoints,
                  breakAfter: coordinator.discontinuityAfterIndices
              ) else { return }
        if let top = coordinator.mainPolylines.last {
            map.insertOverlay(overlay, above: top)
        } else {
            map.addOverlay(overlay, level: .aboveRoads)
        }
        coordinator.unpavedOverlay = overlay
    }

    // MARK: - 하이라이트 overlay만 교체

    private func updateHighlight(map: MKMapView, coordinator: Coordinator) {
        let signature = highlightPoints.map(\.cumKm)
        guard coordinator.highlightSignature != signature else { return }
        coordinator.highlightSignature = signature

        if let hl = coordinator.highlightPolyline { map.removeOverlay(hl) }
        coordinator.highlightPolyline = nil

        guard highlightPoints.count >= 2 else { return }

        let hlCoords = highlightPoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        let hlPolyline = HighlightPolyline(coordinates: hlCoords, count: hlCoords.count)
        map.addOverlay(hlPolyline, level: .aboveRoads)
        coordinator.highlightPolyline = hlPolyline
    }

    private func updateCuePoints(map: MKMapView, coordinator: Coordinator) {
        let newIDs = Set(cuePoints.map(\.id))
        let oldIDs = Set(coordinator.cueAnnotations.map(\.cue.id))
        guard newIDs != oldIDs else { return }

        map.removeAnnotations(coordinator.cueAnnotations)
        coordinator.cueAnnotations = cuePoints.map { CueAnnotation(cue: $0) }
        map.addAnnotations(coordinator.cueAnnotations)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var appliedMapStyle: AppliedMapStyle?
        var builtPointSignature: String = ""
        var unpavedOverlay: CourseUnpavedMultiPolyline?
        var appliedUnpavedRuns: [CourseSurfaceAnalysis.Run]?
        var routeLineWidth: CGFloat = 3
        var highlightSignature: [Double] = []
        var mainPolylines: [MKPolyline] = []
        var highlightPolyline: HighlightPolyline?
        var endpointAnnotations: [EndpointAnnotation] = []
        var cueAnnotations: [CueAnnotation] = []
        var hoverAnnotation: HoverAnnotation?
        var trackPoints: [TrackPoint] = []
        var discontinuityAfterIndices: Set<Int> = []
        var hoverInfo: Binding<RouteHoverInfo?>?
        var onDeselectFocus: (() -> Void)?
        var onSelectCue: ((UUID) -> Void)?
        var onPinDistance: ((Double) -> Void)?
        var lastFocusedCueID: UUID?
        var rangePolylines: [RangeSelectionPolyline] = []
        var rangeEndpointAnnotations: [RangeEndpointAnnotation] = []
        var lastRangeSignature: String = ""
        var appliedZoomResetToken: Int = 0
        var pinnedAnnotation: PinnedLocationAnnotation?
        var lastPinnedSignature: String = ""
        /// 카메라 이동을 판단한 마지막 핀 거리. 트랙 재구성 시 annotation만 다시
        /// 그리는 경우(같은 거리)에는 카메라를 움직이지 않도록 별도로 기억한다.
        var lastRevealedPinnedKm: Double?

        @objc func handleRightClick(_ gesture: NSClickGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let point = gesture.location(in: map)
            let coord = map.convert(point, toCoordinateFrom: map)
            showExternalMapMenu(coord: coord, in: map)
        }

        @objc func handleEmptyAreaClick(_ gesture: NSClickGestureRecognizer) {
            guard let map = gesture.view as? MKMapView else { return }
            let pointInMap = gesture.location(in: map)

            // 좌표 기반 annotation hit-test (hover/pinned dot은 pass-through).
            let hitRadius: CGFloat = 20
            for annotation in map.annotations {
                if annotation is HoverAnnotation { continue }
                if annotation is PinnedLocationAnnotation { continue }
                let annPt = map.convert(annotation.coordinate, toPointTo: map)
                if abs(annPt.x - pointInMap.x) < hitRadius && abs(annPt.y - pointInMap.y) < hitRadius {
                    // annotation 자체 선택은 MKMapView가 처리
                    return
                }
            }

            // 경로 위 클릭 → pin 설정
            if let onPinDistance,
               trackPoints.count >= 2,
               let projection = nearestProjection(in: map, to: pointInMap),
               projection.screenDistance <= hoverHitThreshold,
               let info = routeHoverInfo(
                    trackPoints: trackPoints,
                    segmentStartIndex: projection.segmentStartIndex,
                    fraction: projection.fraction
               ) {
                onPinDistance(info.distanceKm)
                return
            }

            onDeselectFocus?()
        }

        private func showExternalMapMenu(coord: CLLocationCoordinate2D, in map: MKMapView) {
            let menu = NSMenu()

            let kakaoMapItem = NSMenuItem(title: "카카오맵에서 보기",
                                          action: #selector(openKakaoMap(_:)), keyEquivalent: "")
            kakaoMapItem.target = self
            kakaoMapItem.representedObject = coord
            menu.addItem(kakaoMapItem)

            let kakaoRoadviewItem = NSMenuItem(title: "카카오맵 로드뷰에서 보기",
                                               action: #selector(openKakaoRoadview(_:)), keyEquivalent: "")
            kakaoRoadviewItem.target = self
            kakaoRoadviewItem.representedObject = coord
            menu.addItem(kakaoRoadviewItem)

            menu.addItem(.separator())

            let googleMapItem = NSMenuItem(title: "구글 맵에서 보기",
                                           action: #selector(openGoogleMap(_:)), keyEquivalent: "")
            googleMapItem.target = self
            googleMapItem.representedObject = coord
            menu.addItem(googleMapItem)

            let googleRoadviewItem = NSMenuItem(title: "구글 맵에서 로드뷰 보기",
                                                action: #selector(openGoogleRoadview(_:)), keyEquivalent: "")
            googleRoadviewItem.target = self
            googleRoadviewItem.representedObject = coord
            menu.addItem(googleRoadviewItem)

            NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: map)
        }

        @objc private func openKakaoMap(_ sender: NSMenuItem) {
            guard let coord = sender.representedObject as? CLLocationCoordinate2D else { return }
            NSWorkspace.shared.open(KakaoLocalSearch.webURL(lat: coord.latitude, lon: coord.longitude))
        }

        @objc private func openKakaoRoadview(_ sender: NSMenuItem) {
            guard let coord = sender.representedObject as? CLLocationCoordinate2D else { return }
            NSWorkspace.shared.open(KakaoLocalSearch.roadvewURL(lat: coord.latitude, lon: coord.longitude))
        }

        @objc private func openGoogleMap(_ sender: NSMenuItem) {
            guard let coord = sender.representedObject as? CLLocationCoordinate2D else { return }
            NSWorkspace.shared.open(GoogleMapsLink.webURL(lat: coord.latitude, lon: coord.longitude))
        }

        @objc private func openGoogleRoadview(_ sender: NSMenuItem) {
            guard let coord = sender.representedObject as? CLLocationCoordinate2D else { return }
            NSWorkspace.shared.open(GoogleMapsLink.roadviewURL(lat: coord.latitude, lon: coord.longitude))
        }

        private let hoverHitThreshold: CGFloat = 10
        private let tooltip = RouteHoverTooltip()
        private var mapMouseHoverActive = false

        func handleMouseMoved(in map: HoverMapView, point: CGPoint) {
            guard trackPoints.count >= 2,
                  let projection = nearestProjection(in: map, to: point),
                  projection.screenDistance <= hoverHitThreshold,
                  let info = routeHoverInfo(
                    trackPoints: trackPoints,
                    segmentStartIndex: projection.segmentStartIndex,
                    fraction: projection.fraction
                  ) else {
                clearHover(in: map)
                return
            }

            mapMouseHoverActive = true
            hoverInfo?.wrappedValue = info
            updateHoverDot(in: map, info: info)
            tooltip.show(in: map, at: point, info: info)
        }

        func clearHover(in map: MKMapView) {
            mapMouseHoverActive = false
            hoverInfo?.wrappedValue = nil
            removeHoverDot(in: map)
            hideTooltip()
        }

        func syncFocusedCue(in map: MKMapView, focusedID: UUID?) {
            guard let id = focusedID,
                  let annotation = cueAnnotations.first(where: { $0.cue.id == id }) else {
                if let selected = map.selectedAnnotations.first as? CueAnnotation {
                    map.deselectAnnotation(selected, animated: false)
                }
                lastFocusedCueID = nil
                return
            }

            let alreadySelected = (map.selectedAnnotations.first as? CueAnnotation)?.cue.id == id
            if lastFocusedCueID == id, alreadySelected { return }
            lastFocusedCueID = id

            // 화면 밖이거나 가장자리 근처면 중심을 옮긴다 (10% 인셋).
            let mapPoint = MKMapPoint(annotation.coordinate)
            let rect = map.visibleMapRect
            let inset = rect.insetBy(dx: rect.size.width * 0.1, dy: rect.size.height * 0.1)
            if !inset.contains(mapPoint) {
                map.setCenter(annotation.coordinate, animated: true)
            }
            map.selectAnnotation(annotation, animated: true)
        }

        func syncRangeSelection(
            in map: MKMapView,
            selection: ChartRangeSelection?,
            fitsCamera: Bool = false
        ) {
            let sig: String = {
                guard let s = selection, s.lengthKm > 0 else { return "" }
                return String(format: "%.6f|%.6f|%d", s.lowerKm, s.upperKm, s.isDragging ? 1 : 0)
            }()
            guard sig != lastRangeSignature else { return }
            lastRangeSignature = sig

            // 기존 overlay/annotation 제거
            if !rangePolylines.isEmpty { map.removeOverlays(rangePolylines) }
            rangePolylines = []
            if !rangeEndpointAnnotations.isEmpty {
                map.removeAnnotations(rangeEndpointAnnotations)
                rangeEndpointAnnotations = []
            }

            guard let selection, selection.lengthKm > 0 else { return }

            // 섹션 사이는 이어져 있지 않다. 섹션 경계에서는 앞 섹션의 끝점과 뒤 섹션의 시작점이
            // 같은 누적 거리를 가지므로, 전체 트랙에서 한 번에 잘라내면 서로 다른 섹션의 점이
            // 한 선으로 묶여 직선이 그려진다. 섹션(연속 구간)마다 따로 잘라 그린다.
            let lo = selection.lowerKm
            let hi = selection.upperKm
            var pieces: [[TrackPoint]] = []
            for run in continuousRuns() {
                guard let first = run.first, let last = run.last else { continue }
                let runLo = max(lo, first.cumKm)
                let runHi = min(hi, last.cumKm)
                guard runHi - runLo > 0.000_001 else { continue }
                let pts = trackPointsInRange(
                    run,
                    range: ChartRangeSelection(startKm: runLo, endKm: runHi, isDragging: false)
                )
                if pts.count >= 2 { pieces.append(pts) }
            }
            guard let startPoint = pieces.first?.first, let endPoint = pieces.last?.last else { return }

            var rangeRect = MKMapRect.null
            for pts in pieces {
                let coords = pts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                let line = RangeSelectionPolyline(coordinates: coords, count: coords.count)
                rangePolylines.append(line)
                rangeRect = rangeRect.union(line.boundingMapRect)
            }
            map.addOverlays(rangePolylines, level: .aboveRoads)

            // 양 끝점 annotation. 실제로 그린 선의 양 끝에 둔다.
            let anns = [
                RangeEndpointAnnotation(
                    kind: .start, lat: startPoint.lat, lon: startPoint.lon,
                    distanceKm: lo, elevationMeters: startPoint.ele
                ),
                RangeEndpointAnnotation(
                    kind: .end, lat: endPoint.lat, lon: endPoint.lon,
                    distanceKm: hi, elevationMeters: endPoint.ele
                ),
            ]
            map.addAnnotations(anns)
            rangeEndpointAnnotations = anns
            promoteRangeEndpointAnnotationViews(in: map)

            if !selection.isDragging {
                if fitsCamera {
                    fitMapCamera(map, to: rangeRect)
                } else {
                    revealRangeIfNeeded(in: map, rangeRect: rangeRect)
                }
            }
        }

        /// `trackPoints`를 섹션 경계(`discontinuityAfterIndices`)에서 끊은 연속 구간들.
        private func continuousRuns() -> [[TrackPoint]] {
            var runs: [[TrackPoint]] = []
            var start = 0
            for index in discontinuityAfterIndices.sorted() where index >= start && index < trackPoints.count - 1 {
                runs.append(Array(trackPoints[start ... index]))
                start = index + 1
            }
            if start < trackPoints.count {
                runs.append(Array(trackPoints[start...]))
            }
            return runs
        }

        /// 선택 구간이 지도 화면에 다 보이지 않으면 카메라를 옮긴다.
        /// 현재 화면 크기에 들어가는 구간은 확대 수준을 유지한 채 중심만 옮기고,
        /// 화면보다 큰 구간은 구간 전체가 보이도록 축소한다.
        private func revealRangeIfNeeded(in map: MKMapView, rangeRect: MKMapRect) {
            let visible = map.visibleMapRect
            guard !visible.isEmpty, !visible.contains(rangeRect) else { return }

            let fitsAtCurrentZoom = rangeRect.size.width <= visible.size.width * 0.8
                && rangeRect.size.height <= visible.size.height * 0.8
            if fitsAtCurrentZoom {
                let center = MKMapPoint(x: rangeRect.midX, y: rangeRect.midY)
                map.setCenter(center.coordinate, animated: true)
            } else {
                map.setVisibleMapRect(
                    rangeRect,
                    edgePadding: NSEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
                    animated: true
                )
            }
        }

        func syncPinnedLocation(in map: MKMapView, distanceKm: Double?) {
            let sig: String = distanceKm.map { String(format: "%.6f", $0) } ?? ""
            guard sig != lastPinnedSignature else { return }
            lastPinnedSignature = sig

            if let existing = pinnedAnnotation {
                map.removeAnnotation(existing)
                pinnedAnnotation = nil
            }

            let shouldReveal = distanceKm != lastRevealedPinnedKm
            lastRevealedPinnedKm = distanceKm

            guard let km = distanceKm,
                  let info = routeHoverInfo(trackPoints: trackPoints, nearestToDistanceKm: km) else { return }

            let annotation = PinnedLocationAnnotation(
                lat: info.lat, lon: info.lon,
                distanceKm: info.distanceKm,
                elevationMeters: info.elevationMeters
            )
            map.addAnnotation(annotation)
            pinnedAnnotation = annotation
            if shouldReveal {
                revealCoordinateIfNeeded(annotation.coordinate, in: map)
            }
        }

        func syncHoverPresentation(in map: MKMapView, info: RouteHoverInfo?) {
            guard let info else {
                mapMouseHoverActive = false
                removeHoverDot(in: map)
                hideTooltip()
                return
            }

            updateHoverDot(in: map, info: info)
            if !mapMouseHoverActive {
                tooltip.show(in: map, atRoutePointOf: info)
            }
        }

        private func removeHoverDot(in map: MKMapView) {
            if let hoverAnnotation {
                map.removeAnnotation(hoverAnnotation)
                self.hoverAnnotation = nil
            }
        }

        private func updateHoverDot(in map: MKMapView, info: RouteHoverInfo) {
            let coordinate = CLLocationCoordinate2D(latitude: info.lat, longitude: info.lon)
            if let hoverAnnotation {
                hoverAnnotation.coordinate = coordinate
            } else {
                let annotation = HoverAnnotation()
                annotation.coordinate = coordinate
                map.addAnnotation(annotation)
                hoverAnnotation = annotation
            }
        }

        func hideTooltip() {
            tooltip.hide()
        }

        func removeTooltip() {
            tooltip.remove()
        }

        private func nearestProjection(
            in map: MKMapView,
            to point: CGPoint
        ) -> (segmentStartIndex: Int, fraction: Double, screenDistance: CGFloat)? {
            var best: (segmentStartIndex: Int, fraction: Double, screenDistance: CGFloat)?

            for i in 0..<(trackPoints.count - 1) {
                if discontinuityAfterIndices.contains(i) { continue }
                let a = trackPoints[i]
                let b = trackPoints[i + 1]
                let p1 = map.convert(
                    CLLocationCoordinate2D(latitude: a.lat, longitude: a.lon),
                    toPointTo: map
                )
                let p2 = map.convert(
                    CLLocationCoordinate2D(latitude: b.lat, longitude: b.lon),
                    toPointTo: map
                )

                let dx = p2.x - p1.x
                let dy = p2.y - p1.y
                let len2 = dx * dx + dy * dy
                guard len2 > 0 else { continue }

                let rawT = ((point.x - p1.x) * dx + (point.y - p1.y) * dy) / len2
                let t = min(max(rawT, 0), 1)
                let projected = CGPoint(x: p1.x + dx * t, y: p1.y + dy * t)
                let distance = hypot(point.x - projected.x, point.y - projected.y)

                if best == nil || distance < best!.screenDistance {
                    best = (i, Double(t), distance)
                }
            }

            return best
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let cue = view.annotation as? CueAnnotation else { return }
            // 같은 cue를 syncFocusedCue가 다시 select하는 경우는 콜백 발생을 피한다.
            if lastFocusedCueID == cue.cue.id { return }
            lastFocusedCueID = cue.cue.id
            onSelectCue?(cue.cue.id)
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            if views.contains(where: { $0.annotation is RangeEndpointAnnotation }) || !rangeEndpointAnnotations.isEmpty {
                promoteRangeEndpointAnnotationViews(in: mapView)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? GarminTileOverlay {
                return GarminMapRenderer(overlay: tiles, mapView: mapView)
            }
            if let unpaved = overlay as? CourseUnpavedMultiPolyline {
                return CourseUnpavedMultiPolyline.renderer(for: unpaved, routeWidth: routeLineWidth)
            }
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            if polyline is RangeSelectionPolyline {
                renderer.strokeColor = NSColor.systemIndigo
                renderer.lineWidth = 6
            } else if polyline is HighlightPolyline {
                renderer.strokeColor = NSColor.systemCyan
                renderer.lineWidth = 5
            } else {
                renderer.strokeColor = (polyline as? MainRoutePolyline)?.color ?? NSColor.systemOrange
                renderer.lineWidth = routeLineWidth
            }
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is HoverAnnotation {
                let identifier = "hoverPoint"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.image = Self.hoverDotImage
                view.displayPriority = .required
                view.canShowCallout = false
                view.zPriority = .max
                return view
            }

            if annotation is PinnedLocationAnnotation {
                let identifier = "pinnedLocation"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.image = Self.pinnedDotImage
                view.displayPriority = .required
                view.canShowCallout = true
                view.zPriority = .max
                return view
            }

            if let range = annotation as? RangeEndpointAnnotation {
                let identifier = range.kind == .start ? "rangeStart" : "rangeEnd"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                let label = range.kind == .start ? "구간 시작" : "구간 종료"
                let labelText = "\(label) · \(formatRouteDistance(range.distanceKm)) · \(formatRouteElevation(range.elevationMeters))"
                let image = Self.rangeEndpointImage(text: labelText, kind: range.kind)
                v.annotation = annotation
                v.image = image
                v.centerOffset = CGPoint(x: 0, y: -image.size.height / 2)
                configureRangeEndpointAnnotationViewAsTopMost(v)
                return v
            }

            if let cluster = annotation as? MKClusterAnnotation,
               cluster.memberAnnotations.allSatisfy({ $0 is EndpointAnnotation }) {
                let identifier = "routeStartEndPoint"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                let image = Self.startEndEndpointImage
                v.annotation = annotation
                v.image = image
                v.centerOffset = CGPoint(x: 0, y: -image.size.height / 2)
                v.clusteringIdentifier = nil
                v.displayPriority = .required
                v.canShowCallout = false
                v.zPriority = .defaultSelected
                return v
            }

            if let endpoint = annotation as? EndpointAnnotation {
                let identifier = endpoint.kind == .start ? "routeStartPoint" : "routeEndPoint"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                let image = endpoint.kind == .start ? Self.startEndpointImage : Self.endEndpointImage
                v.annotation = annotation
                v.image = image
                v.centerOffset = CGPoint(x: 0, y: -image.size.height / 2)
                v.clusteringIdentifier = Self.endpointClusteringIdentifier
                v.displayPriority = .defaultHigh
                v.canShowCallout = true
                v.zPriority = .defaultSelected
                return v
            }

            guard let ca = annotation as? CueAnnotation else { return nil }
            let glyph = cuePointGlyph(for: ca.cue.pointType)
            let v = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "cuePoint")
            v.clusteringIdentifier = nil
            v.displayPriority = .required
            v.canShowCallout = true
            v.markerTintColor = glyph.color
            if let sym = glyph.symbol {
                v.glyphImage = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            } else if let txt = glyph.text {
                v.glyphText = txt
            }
            v.zPriority = .defaultSelected
            return v
        }

        private static let hoverDotImage: NSImage = makeHoverDotImage()
        static let pinnedDotImage: NSImage = makePinnedDotImage()

        private static let endpointClusteringIdentifier = "routeEndpoint"
        private static let startEndpointImage = endpointLabelImage(text: "Start", color: .systemGreen)
        private static let endEndpointImage = endpointLabelImage(text: "End", color: .systemRed)
        private static let startEndEndpointImage = endpointLabelImage(text: "Start/End", color: .systemBlue)

        static func rangeEndpointImage(text: String, kind: RangeEndpointAnnotation.Kind) -> NSImage {
            let bg = NSColor.systemIndigo
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let textSize = (text as NSString).size(withAttributes: attrs)
            let width = ceil(textSize.width) + 18
            let size = NSSize(width: width, height: 30)
            let image = NSImage(size: size)
            image.lockFocus()
            let midX = size.width / 2
            // 포인터
            let pointer = NSBezierPath()
            pointer.move(to: NSPoint(x: midX, y: 0))
            pointer.line(to: NSPoint(x: midX - 6, y: 7))
            pointer.line(to: NSPoint(x: midX + 6, y: 7))
            pointer.close()
            bg.setFill()
            pointer.fill()
            // pill
            let pillRect = NSRect(x: 1, y: 7, width: size.width - 2, height: 22)
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6)
            bg.setFill()
            pill.fill()
            NSColor.white.withAlphaComponent(0.85).setStroke()
            pill.lineWidth = 1
            pill.stroke()
            // 텍스트
            let tRect = NSRect(
                x: (size.width - textSize.width) / 2,
                y: pillRect.midY - textSize.height / 2,
                width: textSize.width, height: textSize.height
            )
            (text as NSString).draw(in: tRect, withAttributes: attrs)
            image.unlockFocus()
            return image
        }

        private static func endpointLabelImage(text: String, color: NSColor) -> NSImage {
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let textSize = (text as NSString).size(withAttributes: attributes)
            let width = ceil(textSize.width) + 22
            let size = NSSize(width: width, height: 28)
            let image = NSImage(size: size)

            image.lockFocus()
            let midX = size.width / 2
            let pointer = NSBezierPath()
            pointer.move(to: NSPoint(x: midX, y: 0))
            pointer.line(to: NSPoint(x: midX - 6, y: 7))
            pointer.line(to: NSPoint(x: midX + 6, y: 7))
            pointer.close()
            color.setFill()
            pointer.fill()

            let pillRect = NSRect(x: 1, y: 6, width: size.width - 2, height: 21)
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6)
            color.setFill()
            pill.fill()
            NSColor.white.withAlphaComponent(0.75).setStroke()
            pill.lineWidth = 1
            pill.stroke()

            let textRect = NSRect(
                x: (size.width - textSize.width) / 2,
                y: pillRect.midY - textSize.height / 2,
                width: textSize.width,
                height: textSize.height
            )
            (text as NSString).draw(in: textRect, withAttributes: attributes)
            image.unlockFocus()
            return image
        }
    }
}
