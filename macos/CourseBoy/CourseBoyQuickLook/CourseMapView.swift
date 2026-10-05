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
    /// 지도 위를 덮는 내비게이션 바·고도 그래프 카드·탭 바의 폭.
    /// 지도는 그 뒤까지 깔리지만 센터링과 코스 맞춤은 가려지지 않는 영역을 기준으로 한다(layoutMargins로 전달).
    var obscuredInsets = EdgeInsets()
    var mapStyle: CourseMapStyle = .standard
    /// 누를 때마다 증가하는 값. 바뀐 경우에만 코스 전체가 보이게 1회 맞춘다.
    var fitCourseRequest = 0
    /// 지도 탭의 나침반 버튼에 이 지도를 연결한다.
    var compassLink: CourseMapCompassLink?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selectedCueID: $selectedCueID,
            selectedProfilePoint: $selectedProfilePoint,
            onUserStopFollowing: onUserStopFollowing
        )
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = LayoutObservingMapView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        map.onLayout = { [weak coordinator = context.coordinator, weak map] in
            guard let coordinator, let map else { return }
            coordinator.applyPendingFitIfPossible(in: map)
        }
        map.delegate = context.coordinator
        // 나침반은 지도 탭의 버튼 열에 MKCompassButton으로 따로 띄운다.
        map.showsCompass = false
        map.showsScale = true
        context.coordinator.syncMapStyle(mapStyle, in: map)
        context.coordinator.attach(map)
        compassLink?.mapView = map
        return map
    }

    static func dismantleUIView(_ uiView: MKMapView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.selectedCueID = $selectedCueID
        context.coordinator.selectedProfilePoint = $selectedProfilePoint
        context.coordinator.onUserStopFollowing = onUserStopFollowing
        context.coordinator.syncObscuredInsets(
            UIEdgeInsets(
                top: obscuredInsets.top,
                left: obscuredInsets.leading,
                bottom: obscuredInsets.bottom,
                right: obscuredInsets.trailing
            ),
            in: map
        )
        context.coordinator.syncMapStyle(mapStyle, in: map)
        context.coordinator.syncCourse(course, in: map)
        context.coordinator.syncTrackingMode(trackingMode, in: map)
        context.coordinator.syncSelectedCue(selectedCueID, in: map)
        context.coordinator.syncProfileSelection(selectedProfilePoint, in: map)
        context.coordinator.centerOnSelection(
            ifRequested: centerRequest,
            animated: !isScrubbingProfile,
            in: map
        )
        context.coordinator.fitCourse(ifRequested: fitCourseRequest, in: map)
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
        private var handledFitCourseRequest = 0
        /// 코스 전체 보기에 쓰는 여백을 둔 코스 영역.
        private var courseFitRect: MKMapRect?
        private var appliedMapStyle: CourseMapStyle?
        /// 줌에 따라 두께를 맞출 코스 라인 렌더러(경사 색 구간들과 화살표).
        private let routeRenderers = NSHashTable<MKOverlayPathRenderer>.weakObjects()
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
        private var obscuredInsets = UIEdgeInsets.zero
        /// 지도가 아직 배치되지 않아 맞추지 못한 코스 영역. 배치가 끝나면 적용한다.
        private var pendingFitRect: MKMapRect?
        /// 자동으로 코스에 맞춘 직후의 지도 크기와 다시 맞춰도 되는 기한. DocumentGroup은 문서를 여는
        /// 애니메이션 동안 지도를 작게 배치하므로, 그사이 크기가 바뀌면 코스 맞춤을 다시 한다.
        private var provisionalFit: (size: CGSize, until: Date)?

        private static let provisionalFitDuration: TimeInterval = 1.5

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

        func syncMapStyle(_ style: CourseMapStyle, in map: MKMapView) {
            guard style != appliedMapStyle else { return }
            appliedMapStyle = style
            let configuration = style.makeConfiguration()
            // 백그라운드에서는 평면 지도로 바꿔 두었으므로 복귀할 때 쓸 구성을 바꾼다.
            if savedConfiguration != nil {
                savedConfiguration = configuration
            } else {
                map.preferredConfiguration = configuration
            }
        }

        func syncObscuredInsets(_ insets: UIEdgeInsets, in map: MKMapView) {
            guard insets != obscuredInsets else { return }
            obscuredInsets = insets
            // MKMapView는 layoutMargins 안쪽을 보이는 영역으로 본다. setCenter, setVisibleMapRect,
            // 따라가기 센터링과 Legal·나침반·축척 위치가 모두 이 영역을 기준으로 맞춰진다.
            map.insetsLayoutMarginsFromSafeArea = false
            map.layoutMargins = insets
        }

        /// 가려지는 폭을 빼고도 코스를 보여 줄 만큼 지도가 커졌을 때 코스 전체에 맞춘다.
        /// 크기가 0인 상태에서 layoutMargins가 걸린 채 맞추면 지도가 최대로 축소되어 버린다.
        /// 창에 붙기 전에 맞추면 무시되므로 창에 붙은 뒤에만 맞춘다.
        func applyPendingFitIfPossible(in map: MKMapView) {
            if pendingFitRect == nil, let provisionalFit {
                guard Date() < provisionalFit.until else {
                    self.provisionalFit = nil
                    return
                }
                guard map.bounds.size != provisionalFit.size else { return }
                pendingFitRect = courseFitRect
            }
            guard let rect = pendingFitRect,
                  map.window != nil,
                  map.bounds.width > obscuredInsets.left + obscuredInsets.right + 44,
                  map.bounds.height > obscuredInsets.top + obscuredInsets.bottom + 44 else { return }
            pendingFitRect = nil
            map.setVisibleMapRect(rect, animated: false)
            provisionalFit = (map.bounds.size, Date().addingTimeInterval(Self.provisionalFitDuration))
            // 첫 배치 전에 이미 선택이 있었으면(구간 탭에서 진입 등) 코스 맞춤 뒤 다시 센터링한다.
            centerOnCurrentSelection(animated: false, in: map)
        }

        func syncCourse(_ course: LoadedCourse, in map: MKMapView) {
            guard loadedCourseID != course.id else { return }
            loadedCourseID = course.id
            cueAnnotations = []
            endpointAnnotations = []
            courseFitRect = nil
            profileSelectionAnnotation = nil

            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations)

            let coordinates = course.trackPoints.map(\.coordinate)
            if coordinates.count >= 2 {
                // 경사 색마다 MKMultiPolyline 하나로 묶어 MapKit 기본 렌더러로 그린다.
                // MKGradientPolylineRenderer는 확대할수록 타일 하나에 수 초가 걸려 쓰지 않는다.
                var bandLines = [GradeBand: [MKPolyline]]()
                for run in CourseRoutePolyline.gradeRuns(for: course.trackPoints) {
                    let runCoordinates = Array(coordinates[run.startIndex...run.endIndex])
                    bandLines[run.band, default: []].append(
                        MKPolyline(coordinates: runCoordinates, count: runCoordinates.count)
                    )
                }
                for band in GradeBand.allCases {
                    guard let lines = bandLines[band] else { continue }
                    map.addOverlay(CourseGradeMultiPolyline(lines, band: band), level: .aboveRoads)
                }

                // 화살표만 그리는 오버레이. 색 구간들보다 나중에 추가해 위에 그려지게 한다.
                let route = CourseRoutePolyline(coordinates: coordinates, count: coordinates.count)
                map.addOverlay(route, level: .aboveRoads)

                courseFitRect = paddedRect(for: route.boundingMapRect)
                pendingFitRect = courseFitRect
                applyPendingFitIfPossible(in: map)
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

        func fitCourse(ifRequested request: Int, in map: MKMapView) {
            guard request != handledFitCourseRequest else { return }
            handledFitCourseRequest = request
            guard let courseFitRect else { return }
            // 따라가기를 켜며 시작한 확대가 끝나도 다시 따라가지 않게 한다.
            needsFollowZoom = false
            pendingFollowAfterZoom = false
            if map.userTrackingMode != .none {
                setUserTrackingMode(.none, in: map)
            }
            map.setVisibleMapRect(courseFitRect, animated: true)
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
            let renderer: MKOverlayPathRenderer
            if let grade = overlay as? CourseGradeMultiPolyline {
                renderer = MKMultiPolylineRenderer(multiPolyline: grade)
                renderer.strokeColor = UIColor(grade.band.color)
            } else if let route = overlay as? CourseRoutePolyline {
                renderer = CourseRouteRenderer(overlay: route)
            } else {
                return MKOverlayRenderer(overlay: overlay)
            }
            renderer.lineWidth = CourseRouteRenderer.lineWidth(forZoomScale: currentZoomScale(of: mapView))
            renderer.lineJoin = .round
            renderer.lineCap = .round
            routeRenderers.add(renderer)
            return renderer
        }

        private func updateRouteLineWidth(in mapView: MKMapView) {
            let width = CourseRouteRenderer.lineWidth(forZoomScale: currentZoomScale(of: mapView))
            for renderer in routeRenderers.allObjects where renderer.lineWidth != width {
                renderer.lineWidth = width
                renderer.setNeedsDisplay()
            }
        }

        private func currentZoomScale(of mapView: MKMapView) -> MKZoomScale {
            let visibleWidth = mapView.visibleMapRect.width
            guard visibleWidth > 0, mapView.bounds.width > 0 else { return 1 }
            return mapView.bounds.width / visibleWidth
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let endpoint = annotation as? CourseEndpointAnnotation {
                let view = glyphView(for: annotation, identifier: "endpoint", in: mapView)
                view.configure(
                    color: endpoint.kind == .start ? .systemGreen : .systemRed,
                    symbol: endpoint.kind == .start ? "flag.fill" : "flag.checkered",
                    style: .prominentIcon
                )
                // 출발·도착은 코스 선, 큐 마커, 그래프 선택 위치보다 위에 그린다.
                view.zPriority = .max
                view.selectedZPriority = .max
                return view
            }

            if let cueAnnotation = annotation as? CourseCueAnnotation {
                let glyph = cuePointGlyph(for: cueAnnotation.cue.pointType)
                let view = glyphView(for: annotation, identifier: "cue", in: mapView)
                view.configure(color: glyph.uiColor, symbol: glyph.symbol, text: glyph.text)
                return view
            }

            if annotation is CourseProfileSelectionAnnotation {
                let view = glyphView(for: annotation, identifier: "profile-selection", in: mapView)
                view.configure(color: .systemCyan, style: .dot)
                return view
            }

            return nil
        }

        private func glyphView(
            for annotation: MKAnnotation,
            identifier: String,
            in mapView: MKMapView
        ) -> CourseGlyphAnnotationView {
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: identifier
            ) as? CourseGlyphAnnotationView ?? CourseGlyphAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.canShowCallout = true
            view.displayPriority = .required
            return view
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

/// 배치가 끝나거나 창에 붙을 때마다 알려 주는 지도. 첫 배치 뒤에 코스 맞춤을 하기 위해 쓴다.
private final class LayoutObservingMapView: MKMapView {
    var onLayout: () -> Void = {}

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onLayout()
    }
}

/// 같은 경사도 색으로 칠할 구간들.
private final class CourseGradeMultiPolyline: MKMultiPolyline {
    let band: GradeBand

    init(_ polylines: [MKPolyline], band: GradeBand) {
        self.band = band
        super.init(polylines)
    }
}

/// 코스 전체 경로. 진행 방향 화살표를 그리는 데 쓴다.
private final class CourseRoutePolyline: MKPolyline {
    /// 같은 경사도 색으로 칠할 연속 구간. 인덱스는 트랙 포인트 기준이다.
    struct GradeRun {
        var startIndex: Int
        var endIndex: Int
        var band: GradeBand
    }

    /// 이보다 짧은 색 구간은 이웃 구간에 합친다. GPS 고도 노이즈로 색이 잘게 바뀌는 것을 막는다.
    static let minimumRunKm = 0.1

    /// 고도 그래프와 같은 순간 경사도로 구간을 나눈 뒤 minimumRunKm보다 짧은 구간을 이웃에 합친다.
    static func gradeRuns(for trackPoints: [TrackPoint]) -> [GradeRun] {
        guard trackPoints.count >= 2 else { return [] }
        let samples = MapElevationProfile(trackPoints: trackPoints).samples

        // 포인트 index-1 → index 구간은 끝 포인트의 경사도로 칠한다. 고도가 없는 포인트는 앞 값을 쓴다.
        var runs: [GradeRun] = []
        var cursor = 0
        var grade = samples.first?.grade ?? 0
        for index in 1..<trackPoints.count {
            while cursor < samples.count, samples[cursor].trackIndex <= index {
                grade = samples[cursor].grade
                cursor += 1
            }
            let band = GradeBand(grade: grade)
            if let last = runs.last, last.band == band {
                runs[runs.count - 1].endIndex = index
            } else {
                runs.append(GradeRun(startIndex: index - 1, endIndex: index, band: band))
            }
        }

        func length(_ run: GradeRun) -> Double {
            trackPoints[run.endIndex].cumKm - trackPoints[run.startIndex].cumKm
        }

        // 가장 짧은 구간부터 경사도가 더 비슷한(같으면 더 긴) 이웃에 흡수시킨다.
        while runs.count > 1,
              let shortest = runs.indices.min(by: { length(runs[$0]) < length(runs[$1]) }),
              length(runs[shortest]) < minimumRunKm {
            let run = runs[shortest]
            let target: Int
            if shortest == 0 {
                target = 1
            } else if shortest == runs.count - 1 {
                target = shortest - 1
            } else {
                let previous = runs[shortest - 1]
                let next = runs[shortest + 1]
                let previousGap = abs(previous.band.order - run.band.order)
                let nextGap = abs(next.band.order - run.band.order)
                if previousGap != nextGap {
                    target = previousGap < nextGap ? shortest - 1 : shortest + 1
                } else {
                    target = length(previous) >= length(next) ? shortest - 1 : shortest + 1
                }
            }
            runs[target].startIndex = min(runs[target].startIndex, run.startIndex)
            runs[target].endIndex = max(runs[target].endIndex, run.endIndex)
            runs.remove(at: shortest)

            // 흡수 후 같은 색이 된 양옆 구간을 하나로 잇는다.
            let merged = target < shortest ? target : target - 1
            if merged + 1 < runs.count, runs[merged + 1].band == runs[merged].band {
                runs[merged].endIndex = runs[merged + 1].endIndex
                runs.remove(at: merged + 1)
            }
            if merged > 0, runs[merged - 1].band == runs[merged].band {
                runs[merged - 1].endIndex = runs[merged].endIndex
                runs.remove(at: merged)
            }
        }
        return runs
    }
}

/// 코스 라인 위에 진행 방향 화살표(›)를 일정한 화면 간격으로 그린다. 라인 자체는 CourseGradeMultiPolyline이 그린다.
private final class CourseRouteRenderer: MKPolylineRenderer {
    private static let arrowSpacing: CGFloat = 216
    /// lineWidth 대비 화살표 크기 비율.
    private static let arrowArmRatio: CGFloat = 0.15
    private static let arrowLineWidthRatio: CGFloat = 0.09
    private static let minimumArrowCount: CGFloat = 3
    private static let baseLineWidth: CGFloat = 6
    /// 이 줌 레벨 이하에서는 라인을 minimumWidthFactor 배로 가늘게, fullWidthZoomLevel 이상에서는 원래 두께로 그린다.
    private static let thinZoomLevel: CGFloat = 9
    private static let fullWidthZoomLevel: CGFloat = 13
    private static let minimumWidthFactor: CGFloat = 0.45
    /// 확대할수록 라인 대비 화살표가 커 보여서, shrinkArrowZoomLevel부터 smallestArrowZoomLevel까지 화살표를 smallestArrowFactor 배까지 줄인다.
    private static let shrinkArrowZoomLevel: CGFloat = 15
    private static let smallestArrowZoomLevel: CGFloat = 18
    private static let smallestArrowFactor: CGFloat = 0.6

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

    private static func arrowSizeFactor(forZoomScale zoomScale: MKZoomScale) -> CGFloat {
        let zoomLevel = 20 + log2(zoomScale)
        let progress = (zoomLevel - shrinkArrowZoomLevel) / (smallestArrowZoomLevel - shrinkArrowZoomLevel)
        return 1 - (1 - smallestArrowFactor) * min(max(progress, 0), 1)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        // 라인은 그리지 않고 화살표만 그린다.
        drawArrows(mapRect, zoomScale: zoomScale, in: context)
    }

    private func drawArrows(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let pointCount = polyline.pointCount
        guard pointCount >= 2, cumulativeLengths.count == pointCount, let totalLength = cumulativeLengths.last, totalLength > 0 else { return }

        // 맵 포인트 단위 간격. 화면에서는 항상 arrowSpacing(pt) 간격으로 보인다.
        let spacing = Double(Self.arrowSpacing / zoomScale)
        guard totalLength >= spacing * Double(Self.minimumArrowCount) else { return }

        // 라인과 같은 배율(MKRoadWidthAtZoomScale)을 기준으로 하되, 많이 확대하면 라인 대비 조금 작게 그린다.
        let unit = lineWidth * MKRoadWidthAtZoomScale(zoomScale) * Self.arrowSizeFactor(forZoomScale: zoomScale)
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
        // 말풍선은 타입을 제목으로, 이름을 부제로 보여준다. 이름이 없으면 타입만 둔다.
        self.title = cuePointLabel(for: cue.pointType)
        let name = cue.name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.subtitle = name.isEmpty ? nil : name
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
        subtitle = nil
    }
}

/// 고도 그래프의 큐 아이콘과 같은 모양의 작은 원형 지도 마커.
/// 기본 풍선 마커는 크기를 줄일 수 없어 코스 선을 많이 가리므로 직접 그린다.
private final class CourseGlyphAnnotationView: MKAnnotationView {
    enum Style {
        /// 색 원 안에 심볼이나 글자를 넣는다.
        case icon
        /// `icon`보다 조금 큰 원. 출발·도착처럼 잘 보여야 하는 마커.
        case prominentIcon
        /// 아이콘 없이 작은 점만 찍는다. 그래프 선택 위치처럼 위치만 알리면 되는 경우.
        case dot
    }

    private static let iconDiameter: CGFloat = 22
    private static let prominentIconDiameter: CGFloat = 28
    private static let dotDiameter: CGFloat = 14
    private static let selectedScale: CGFloat = 30 / 22

    private let circleView = UIView()
    private let imageView = UIImageView()
    private let label = UILabel()
    private var style: Style = .icon

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        collisionMode = .circle
        backgroundColor = .clear

        circleView.layer.borderColor = UIColor.white.cgColor
        circleView.layer.shadowColor = UIColor.black.cgColor
        circleView.layer.shadowOpacity = 0.3
        circleView.layer.shadowRadius = 2
        circleView.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(circleView)

        imageView.contentMode = .scaleAspectFit
        imageView.tintColor = .white
        circleView.addSubview(imageView)

        label.textColor = .white
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        circleView.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(color: UIColor, symbol: String? = nil, text: String? = nil, style: Style = .icon) {
        self.style = style
        circleView.backgroundColor = color
        let isIcon = style != .dot
        let diameter: CGFloat = switch style {
        case .icon: Self.iconDiameter
        case .prominentIcon: Self.prominentIconDiameter
        case .dot: Self.dotDiameter
        }
        // 선택 시 커지는 크기만큼 영역을 미리 잡아 콜아웃이 확대된 원 바로 위에 붙게 한다.
        let side = diameter * Self.selectedScale
        bounds = CGRect(x: 0, y: 0, width: side, height: side)
        circleView.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        circleView.center = CGPoint(x: side / 2, y: side / 2)
        circleView.layer.cornerRadius = diameter / 2
        circleView.layer.borderWidth = switch style {
        case .icon: 1.5
        case .prominentIcon, .dot: 2
        }

        let iconSide = diameter * 0.55
        let iconFrame = CGRect(
            x: (diameter - iconSide) / 2,
            y: (diameter - iconSide) / 2,
            width: iconSide,
            height: iconSide
        )
        imageView.frame = iconFrame
        label.frame = iconFrame.insetBy(dx: -2, dy: 0)
        if isIcon, let symbol {
            imageView.image = UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: iconSide, weight: .semibold)
            )
            imageView.isHidden = false
        } else {
            imageView.image = nil
            imageView.isHidden = true
        }
        label.font = .systemFont(ofSize: diameter * 0.5, weight: .bold)
        label.text = isIcon && symbol == nil ? text : nil
        label.isHidden = label.text == nil
        applySelection(animated: false)
    }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        applySelection(animated: animated)
    }

    private func applySelection(animated: Bool) {
        let transform = isSelected
            ? CGAffineTransform(scaleX: Self.selectedScale, y: Self.selectedScale)
            : .identity
        guard animated else {
            circleView.transform = transform
            return
        }
        UIView.animate(
            withDuration: 0.25,
            delay: 0,
            usingSpringWithDamping: 0.7,
            initialSpringVelocity: 0
        ) {
            self.circleView.transform = transform
        }
    }
}
