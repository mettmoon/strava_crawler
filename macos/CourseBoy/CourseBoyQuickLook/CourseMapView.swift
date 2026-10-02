import CoursePreviewCore
import MapKit
import SwiftUI
import UIKit

struct CourseMapView: UIViewRepresentable {
    let course: LoadedCourse
    @Binding var selectedCueID: UUID?
    @Binding var selectedProfilePoint: CourseProfileSelection?
    let trackingMode: CourseLocationTracker.Mode
    var onUserStopFollowing: () -> Void = {}
    /// 고도 그래프를 길게 눌러 조정하는 중이면 지도가 손가락을 바로 따라오도록 애니메이션 없이 이동한다.
    var isScrubbingProfile = false
    /// 선택할 때마다 증가하는 값. 바뀐 경우에만 선택 지점으로 1회 이동한다.
    /// updateUIView는 위치 갱신 등으로 자주 불리므로, 매번 센터링하면 사용자의 지도 이동이나 따라가기를 방해한다.
    var centerRequest = 0

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selectedCueID: $selectedCueID,
            selectedProfilePoint: $selectedProfilePoint,
            onUserStopFollowing: onUserStopFollowing
        )
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
        context.coordinator.attach(map)
        return map
    }

    static func dismantleUIView(_ uiView: MKMapView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.selectedCueID = $selectedCueID
        context.coordinator.selectedProfilePoint = $selectedProfilePoint
        context.coordinator.onUserStopFollowing = onUserStopFollowing
        context.coordinator.syncCourse(course, in: map)
        context.coordinator.syncTrackingMode(trackingMode, in: map)
        context.coordinator.syncSelectedCue(selectedCueID, in: map)
        context.coordinator.syncProfileSelection(selectedProfilePoint, in: map)
        context.coordinator.centerOnSelection(
            ifRequested: centerRequest,
            animated: !isScrubbingProfile,
            in: map
        )
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        /// 따라가기를 켤 때 이보다 넓게 보고 있으면 followZoomMeters로 확대한다.
        private static let followZoomThresholdMeters: CLLocationDistance = 3_000
        private static let followZoomMeters: CLLocationDistance = 700

        var selectedCueID: Binding<UUID?>
        var selectedProfilePoint: Binding<CourseProfileSelection?>
        var onUserStopFollowing: () -> Void
        private var loadedCourseID: UUID?
        private var cueAnnotations: [CourseCueAnnotation] = []
        private var endpointAnnotations: [CourseEndpointAnnotation] = []
        private var profileSelectionAnnotation: CourseProfileSelectionAnnotation?
        private var handledCenterRequest = 0
        private weak var routeRenderer: CourseRouteRenderer?
        private var trackingMode: CourseLocationTracker.Mode = .off
        private var needsFollowZoom = false
        /// 확대 애니메이션이 끝난 뒤(regionDidChange) 따라가기를 켜야 하는지.
        private var pendingFollowAfterZoom = false
        private var isChangingTrackingModeProgrammatically = false
        private var isInBackground = false
        private weak var attachedMap: MKMapView?
        private var didEnterBackgroundObserver: NSObjectProtocol?
        private var willEnterForegroundObserver: NSObjectProtocol?
        private var savedConfiguration: MKMapConfiguration?

        init(
            selectedCueID: Binding<UUID?>,
            selectedProfilePoint: Binding<CourseProfileSelection?>,
            onUserStopFollowing: @escaping () -> Void
        ) {
            self.selectedCueID = selectedCueID
            self.selectedProfilePoint = selectedProfilePoint
            self.onUserStopFollowing = onUserStopFollowing
            super.init()
        }

        deinit {
            if let observer = didEnterBackgroundObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = willEnterForegroundObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func attach(_ map: MKMapView) {
            attachedMap = map
            let center = NotificationCenter.default
            didEnterBackgroundObserver = center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleDidEnterBackground()
            }
            willEnterForegroundObserver = center.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleWillEnterForeground()
            }
        }

        func detach() {
            if let observer = didEnterBackgroundObserver {
                NotificationCenter.default.removeObserver(observer)
                didEnterBackgroundObserver = nil
            }
            if let observer = willEnterForegroundObserver {
                NotificationCenter.default.removeObserver(observer)
                willEnterForegroundObserver = nil
            }
            attachedMap = nil
        }

        private func handleDidEnterBackground() {
            isInBackground = true
            guard let map = attachedMap else { return }
            map.showsUserLocation = false

            if savedConfiguration == nil {
                savedConfiguration = map.preferredConfiguration
                let flat = MKStandardMapConfiguration(elevationStyle: .flat)
                flat.pointOfInterestFilter = .excludingAll
                map.preferredConfiguration = flat
            }
        }

        private func handleWillEnterForeground() {
            isInBackground = false
            guard let map = attachedMap else { return }
            if let saved = savedConfiguration {
                map.preferredConfiguration = saved
                savedConfiguration = nil
            }
            let mode = trackingMode
            trackingMode = .off
            syncTrackingMode(mode, in: map)
        }

        func syncCourse(_ course: LoadedCourse, in map: MKMapView) {
            guard loadedCourseID != course.id else { return }
            loadedCourseID = course.id
            cueAnnotations = []
            endpointAnnotations = []
            profileSelectionAnnotation = nil

            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations)

            let coordinates = course.trackPoints.map(\.coordinate)
            if coordinates.count >= 2 {
                let route = CourseRoutePolyline(coordinates: coordinates, count: coordinates.count)
                map.addOverlay(route, level: .aboveRoads)

                let rect = paddedRect(for: route.boundingMapRect)
                if map.bounds.size == .zero {
                    DispatchQueue.main.async { [weak self] in
                        map.setVisibleMapRect(rect, animated: false)
                        // 첫 배치 전에 이미 선택이 있었으면(구간 탭에서 진입 등) 코스 맞춤 뒤 다시 센터링한다.
                        self?.centerOnCurrentSelection(animated: false, in: map)
                    }
                } else {
                    map.setVisibleMapRect(rect, animated: false)
                }
            }

            if let first = course.trackPoints.first {
                let annotation = CourseEndpointAnnotation(kind: .start, point: first, trackIndex: 0)
                endpointAnnotations.append(annotation)
                map.addAnnotation(annotation)
            }
            if course.trackPoints.count > 1, let last = course.trackPoints.last {
                let annotation = CourseEndpointAnnotation(
                    kind: .end,
                    point: last,
                    trackIndex: course.trackPoints.count - 1
                )
                endpointAnnotations.append(annotation)
                map.addAnnotation(annotation)
            }

            cueAnnotations = course.sortedCuePoints.map(CourseCueAnnotation.init)
            map.addAnnotations(cueAnnotations)
        }

        func syncTrackingMode(_ mode: CourseLocationTracker.Mode, in map: MKMapView) {
            guard !isInBackground else {
                trackingMode = mode
                return
            }
            let previousMode = trackingMode
            trackingMode = mode
            map.showsUserLocation = mode != .off

            let desired: MKUserTrackingMode = mode == .following ? .follow : .none
            if mode == .following, previousMode != .following {
                needsFollowZoom = isZoomedOutForFollowing(map)
                applyFollowZoomIfPossible(in: map)
            }
            // 확대 애니메이션 중에는 follow를 걸지 않는다. 끝나면 regionDidChange에서 건다.
            if map.userTrackingMode != desired, desired == .none || !pendingFollowAfterZoom {
                setUserTrackingMode(desired, in: map)
            }
        }

        private func isZoomedOutForFollowing(_ map: MKMapView) -> Bool {
            let region = map.region
            let metersPerDegreeLatitude = 111_000.0
            return region.span.latitudeDelta * metersPerDegreeLatitude > Self.followZoomThresholdMeters
        }

        private func applyFollowZoomIfPossible(in map: MKMapView) {
            guard needsFollowZoom, let location = map.userLocation.location else { return }
            needsFollowZoom = false
            let region = MKCoordinateRegion(
                center: location.coordinate,
                latitudinalMeters: Self.followZoomMeters,
                longitudinalMeters: Self.followZoomMeters
            )
            pendingFollowAfterZoom = true
            isChangingTrackingModeProgrammatically = true
            map.setRegion(region, animated: true)
            isChangingTrackingModeProgrammatically = false
        }

        private func setUserTrackingMode(_ mode: MKUserTrackingMode, in map: MKMapView) {
            isChangingTrackingModeProgrammatically = true
            map.setUserTrackingMode(mode, animated: true)
            isChangingTrackingModeProgrammatically = false
        }

        func syncSelectedCue(_ id: UUID?, in map: MKMapView) {
            guard let id,
                  let annotation = cueAnnotations.first(where: { $0.cue.id == id }) else {
                if let selected = map.selectedAnnotations.first as? CourseCueAnnotation {
                    map.deselectAnnotation(selected, animated: true)
                }
                return
            }

            if !map.selectedAnnotations.contains(where: { ($0 as? CourseCueAnnotation)?.cue.id == id }) {
                map.selectAnnotation(annotation, animated: true)
            }
        }

        func syncProfileSelection(_ selection: CourseProfileSelection?, in map: MKMapView) {
            guard let selection else {
                if let profileSelectionAnnotation {
                    map.removeAnnotation(profileSelectionAnnotation)
                    self.profileSelectionAnnotation = nil
                }
                deselectEndpointAnnotations(in: map)
                return
            }

            if let endpoint = endpointAnnotation(matching: selection) {
                if let profileSelectionAnnotation {
                    map.removeAnnotation(profileSelectionAnnotation)
                    self.profileSelectionAnnotation = nil
                }
                if !map.selectedAnnotations.contains(where: { ($0 as? CourseEndpointAnnotation) === endpoint }) {
                    deselectEndpointAnnotations(in: map, except: endpoint)
                    map.selectAnnotation(endpoint, animated: true)
                }
                return
            }

            deselectEndpointAnnotations(in: map)

            let annotation: CourseProfileSelectionAnnotation
            if let existing = profileSelectionAnnotation {
                existing.update(selection: selection)
                annotation = existing
            } else {
                annotation = CourseProfileSelectionAnnotation(selection: selection)
                profileSelectionAnnotation = annotation
                map.addAnnotation(annotation)
            }
            // 큐 마커처럼 선택 상태로 둬서, 지도 빈 곳을 누르면 선택이 풀리게 한다.
            if !map.selectedAnnotations.contains(where: { $0 === annotation }) {
                map.selectAnnotation(annotation, animated: true)
            }
        }

        func centerOnSelection(ifRequested request: Int, animated: Bool, in map: MKMapView) {
            guard request != handledCenterRequest else { return }
            handledCenterRequest = request
            centerOnCurrentSelection(animated: animated, in: map)
        }

        private func centerOnCurrentSelection(animated: Bool, in map: MKMapView) {
            if let id = selectedCueID.wrappedValue,
               let annotation = cueAnnotations.first(where: { $0.cue.id == id }) {
                map.setCenter(annotation.coordinate, animated: animated)
            } else if let selection = selectedProfilePoint.wrappedValue {
                map.setCenter(selection.coordinate, animated: animated)
            }
        }

        private func endpointAnnotation(matching selection: CourseProfileSelection) -> CourseEndpointAnnotation? {
            endpointAnnotations.first { $0.trackIndex == selection.trackIndex }
        }

        private func deselectEndpointAnnotations(in map: MKMapView, except keep: CourseEndpointAnnotation? = nil) {
            for annotation in map.selectedAnnotations {
                guard let endpoint = annotation as? CourseEndpointAnnotation, endpoint !== keep else { continue }
                map.deselectAnnotation(endpoint, animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let route = overlay as? CourseRoutePolyline {
                let renderer = CourseRouteRenderer(overlay: route)
                renderer.strokeColor = UIColor.systemBlue
                renderer.lineWidth = CourseRouteRenderer.lineWidth(forZoomScale: currentZoomScale(of: mapView))
                routeRenderer = renderer
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        private func updateRouteLineWidth(in mapView: MKMapView) {
            guard let routeRenderer else { return }
            let width = CourseRouteRenderer.lineWidth(forZoomScale: currentZoomScale(of: mapView))
            guard routeRenderer.lineWidth != width else { return }
            routeRenderer.lineWidth = width
            routeRenderer.setNeedsDisplay()
        }

        private func currentZoomScale(of mapView: MKMapView) -> MKZoomScale {
            let visibleWidth = mapView.visibleMapRect.width
            guard visibleWidth > 0, mapView.bounds.width > 0 else { return 1 }
            return mapView.bounds.width / visibleWidth
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let endpoint = annotation as? CourseEndpointAnnotation {
                let identifier = "endpoint"
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: identifier
                ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.canShowCallout = true
                view.markerTintColor = endpoint.kind == .start ? .systemGreen : .systemRed
                view.glyphImage = UIImage(systemName: endpoint.kind == .start ? "flag.fill" : "flag.checkered")
                view.displayPriority = .required
                return view
            }

            if let cueAnnotation = annotation as? CourseCueAnnotation {
                let identifier = "cue"
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: identifier
                ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                let glyph = cuePointGlyph(for: cueAnnotation.cue.pointType)
                view.annotation = annotation
                view.canShowCallout = true
                view.markerTintColor = glyph.uiColor
                view.glyphImage = glyph.symbol.flatMap { UIImage(systemName: $0) }
                view.glyphText = glyph.text
                view.displayPriority = .required
                return view
            }

            if let profileAnnotation = annotation as? CourseProfileSelectionAnnotation {
                let identifier = "profile-selection"
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: identifier
                ) as? MKMarkerAnnotationView ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = profileAnnotation
                view.canShowCallout = true
                view.markerTintColor = .systemCyan
                view.glyphImage = UIImage(systemName: "scope")
                view.displayPriority = .required
                return view
            }

            return nil
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cue = view.annotation as? CourseCueAnnotation {
                selectedProfilePoint.wrappedValue = nil
                selectedCueID.wrappedValue = cue.cue.id
                return
            }
            if let endpoint = view.annotation as? CourseEndpointAnnotation {
                selectedCueID.wrappedValue = nil
                let selection = CourseProfileSelection(
                    trackIndex: endpoint.trackIndex,
                    point: endpoint.point
                )
                if selectedProfilePoint.wrappedValue != selection {
                    selectedProfilePoint.wrappedValue = selection
                }
                return
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            if view.annotation is CourseCueAnnotation {
                if mapView.selectedAnnotations.compactMap({ $0 as? CourseCueAnnotation }).isEmpty {
                    selectedCueID.wrappedValue = nil
                }
                return
            }
            if let endpoint = view.annotation as? CourseEndpointAnnotation,
               selectedProfilePoint.wrappedValue?.trackIndex == endpoint.trackIndex {
                selectedProfilePoint.wrappedValue = nil
                return
            }
            // 시작/종료점으로 바뀌며 마커가 제거될 때는 마커가 가진 선택이 현재 선택과 달라서 건너뛴다.
            if let profileAnnotation = view.annotation as? CourseProfileSelectionAnnotation,
               selectedProfilePoint.wrappedValue == profileAnnotation.selection {
                selectedProfilePoint.wrappedValue = nil
            }
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            guard trackingMode == .following else { return }
            applyFollowZoomIfPossible(in: mapView)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            updateRouteLineWidth(in: mapView)
            guard pendingFollowAfterZoom else { return }
            pendingFollowAfterZoom = false
            if trackingMode == .following, mapView.userTrackingMode != .follow {
                setUserTrackingMode(.follow, in: mapView)
            }
        }

        func mapView(_ mapView: MKMapView, didChange mode: MKUserTrackingMode, animated: Bool) {
            // 사용자가 지도를 끌어서 따라가기가 풀린 경우에만 트래커에 알린다.
            guard mode == .none,
                  trackingMode == .following,
                  !isChangingTrackingModeProgrammatically,
                  !pendingFollowAfterZoom,
                  !isInBackground else {
                return
            }
            onUserStopFollowing()
        }

        private func paddedRect(for rect: MKMapRect) -> MKMapRect {
            let paddingX = max(rect.width * 0.12, 1200)
            let paddingY = max(rect.height * 0.12, 1200)
            return rect.insetBy(dx: -paddingX, dy: -paddingY)
        }
    }
}

private final class CourseRoutePolyline: MKPolyline {}

/// 코스 라인 위에 진행 방향 화살표(›)를 일정한 화면 간격으로 그린다.
private final class CourseRouteRenderer: MKPolylineRenderer {
    private static let arrowSpacing: CGFloat = 72
    /// lineWidth 대비 화살표 크기 비율.
    private static let arrowArmRatio: CGFloat = 0.15
    private static let arrowLineWidthRatio: CGFloat = 0.09
    private static let minimumArrowCount: CGFloat = 3
    private static let baseLineWidth: CGFloat = 6
    /// 이 줌 레벨 이하에서는 라인을 minimumWidthFactor 배로 가늘게, fullWidthZoomLevel 이상에서는 원래 두께로 그린다.
    private static let thinZoomLevel: CGFloat = 9
    private static let fullWidthZoomLevel: CGFloat = 13
    private static let minimumWidthFactor: CGFloat = 0.45

    /// 경로 시작점부터 각 포인트까지의 누적 길이(맵 포인트 단위).
    private let cumulativeLengths: [Double]

    // MapKit 내부에서 init(overlay:)로 생성하므로 이 이니셜라이저를 재정의한다.
    override init(overlay: MKOverlay) {
        var lengths: [Double] = []
        if let polyline = overlay as? MKPolyline, polyline.pointCount > 0 {
            let points = polyline.points()
            lengths = [Double](repeating: 0, count: polyline.pointCount)
            for index in stride(from: 1, to: polyline.pointCount, by: 1) {
                let dx = points[index].x - points[index - 1].x
                let dy = points[index].y - points[index - 1].y
                lengths[index] = lengths[index - 1] + (dx * dx + dy * dy).squareRoot()
            }
        }
        cumulativeLengths = lengths
        super.init(overlay: overlay)
    }

    /// MapKit 기본 두께는 축소할수록 두꺼워 보여서 줌 레벨에 따라 lineWidth를 줄인다.
    static func lineWidth(forZoomScale zoomScale: MKZoomScale) -> CGFloat {
        let zoomLevel = 20 + log2(zoomScale)
        let progress = (zoomLevel - thinZoomLevel) / (fullWidthZoomLevel - thinZoomLevel)
        let factor = minimumWidthFactor + (1 - minimumWidthFactor) * min(max(progress, 0), 1)
        return (baseLineWidth * factor * 2).rounded() / 2
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        super.draw(mapRect, zoomScale: zoomScale, in: context)

        let pointCount = polyline.pointCount
        guard pointCount >= 2, cumulativeLengths.count == pointCount, let totalLength = cumulativeLengths.last, totalLength > 0 else { return }

        // 맵 포인트 단위 간격. 화면에서는 항상 arrowSpacing(pt) 간격으로 보인다.
        let spacing = Double(Self.arrowSpacing / zoomScale)
        guard totalLength >= spacing * Double(Self.minimumArrowCount) else { return }

        // 라인과 같은 배율(MKRoadWidthAtZoomScale)을 써서 확대 수준과 관계없이 라인 대비 크기를 유지한다.
        let unit = lineWidth * MKRoadWidthAtZoomScale(zoomScale)
        let arm = Double(unit * Self.arrowArmRatio)
        let margin = arm * 2
        let clipRect = mapRect.insetBy(dx: -margin, dy: -margin)
        let points = polyline.points()

        let path = CGMutablePath()
        for index in 0..<(pointCount - 1) {
            let start = points[index]
            let end = points[index + 1]
            let segmentRect = MKMapRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            guard segmentRect.intersects(clipRect) else { continue }

            let startLength = cumulativeLengths[index]
            let segmentLength = cumulativeLengths[index + 1] - startLength
            guard segmentLength > 0 else { continue }

            let dx = (end.x - start.x) / segmentLength
            let dy = (end.y - start.y) / segmentLength

            // 경로 전체 기준 간격 위치를 사용해 타일 경계에서도 화살표가 어긋나지 않게 한다.
            var arrowLength = (startLength / spacing).rounded(.up) * spacing
            if arrowLength == 0 { arrowLength = spacing }
            while arrowLength < startLength + segmentLength {
                guard arrowLength < totalLength - spacing * 0.5 else { break }
                let offset = arrowLength - startLength
                let tip = MKMapPoint(x: start.x + dx * offset, y: start.y + dy * offset)
                appendArrow(to: path, tip: tip, dx: dx, dy: dy, arm: arm)
                arrowLength += spacing
            }
        }

        guard !path.isEmpty else { return }
        context.addPath(path)
        context.setStrokeColor(UIColor.white.cgColor)
        context.setLineWidth(unit * Self.arrowLineWidthRatio)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
    }

    private func appendArrow(to path: CGMutablePath, tip: MKMapPoint, dx: Double, dy: Double, arm: Double) {
        // 진행 방향 벡터(dx, dy)와 수직 벡터(-dy, dx)로 › 모양을 만든다.
        let back = MKMapPoint(x: tip.x - dx * arm, y: tip.y - dy * arm)
        let left = MKMapPoint(x: back.x - dy * arm, y: back.y + dx * arm)
        let right = MKMapPoint(x: back.x + dy * arm, y: back.y - dx * arm)
        path.move(to: point(for: left))
        path.addLine(to: point(for: tip))
        path.addLine(to: point(for: right))
    }
}

private final class CourseEndpointAnnotation: NSObject, MKAnnotation {
    enum Kind {
        case start
        case end
    }

    let kind: Kind
    let point: TrackPoint
    let trackIndex: Int
    let coordinate: CLLocationCoordinate2D
    let title: String?
    var subtitle: String? {
        "\(formatRouteDistance(point.cumKm)) · \(formatRouteElevation(point.ele))"
    }

    init(kind: Kind, point: TrackPoint, trackIndex: Int) {
        self.kind = kind
        self.point = point
        self.trackIndex = trackIndex
        self.coordinate = point.coordinate
        self.title = kind == .start ? "시작점" : "종료점"
    }
}

private final class CourseCueAnnotation: NSObject, MKAnnotation {
    let cue: CourseCuePoint
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?

    init(cue: CourseCuePoint) {
        self.cue = cue
        self.coordinate = cue.coordinate
        self.title = cue.displayName
        self.subtitle = "\(formatRouteDistance(cue.distanceKm)) · \(cuePointLabel(for: cue.pointType))"
    }
}

private final class CourseProfileSelectionAnnotation: NSObject, MKAnnotation {
    private(set) var selection: CourseProfileSelection
    @objc dynamic private(set) var coordinate: CLLocationCoordinate2D
    private(set) var title: String?
    private(set) var subtitle: String?

    init(selection: CourseProfileSelection) {
        self.selection = selection
        self.coordinate = selection.coordinate
        super.init()
        updateTitle()
    }

    func update(selection: CourseProfileSelection) {
        self.selection = selection
        coordinate = selection.coordinate
        updateTitle()
    }

    private func updateTitle() {
        title = "그래프 선택 위치"
        subtitle = "\(formatRouteDistance(selection.distanceKm)) · \(formatRouteElevation(selection.elevationMeters))"
    }
}
