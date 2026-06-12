import SwiftUI
import MapKit
import StravaTCXKit

final class HighlightPolyline: MKPolyline {}

final class CueAnnotation: MKPointAnnotation {
    let cue: CourseCuePoint
    init(cue: CourseCuePoint) {
        self.cue = cue
        super.init()
        coordinate = CLLocationCoordinate2D(latitude: cue.lat, longitude: cue.lon)
        title = cue.name.isEmpty ? cue.pointType : cue.name
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

struct RouteMapView: View {
    let trackPoints: [TrackPoint]
    var highlightPoints: [TrackPoint] = []
    var cuePoints: [CourseCuePoint] = []
    var focusedCueID: UUID? = nil
    /// 빈 영역(어떤 annotation도 아닌 곳) 클릭 시 호출. 큐 포커스 해제 등에 사용.
    var onDeselectFocus: (() -> Void)? = nil
    /// 사용자가 지도의 cue 핀을 직접 탭했을 때 호출. 인스펙터/그래프 선택 동기화에 사용.
    var onSelectCue: ((UUID) -> Void)? = nil
    @Binding var hoverInfo: RouteHoverInfo?

    @AppStorage(MapStyleStorageKey.main) private var mapStyleRaw: String = MapStyleOption.standard.rawValue

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
                highlightPoints: highlightPoints,
                cuePoints: cuePoints,
                focusedCueID: focusedCueID,
                onDeselectFocus: onDeselectFocus,
                onSelectCue: onSelectCue,
                hoverInfo: $hoverInfo,
                mapStyle: mapStyle.wrappedValue
            )
            MapStylePicker(selection: mapStyle)
                .padding(8)
        }
    }
}

private struct RouteMapRepresentable: NSViewRepresentable {
    let trackPoints: [TrackPoint]
    var highlightPoints: [TrackPoint] = []
    var cuePoints: [CourseCuePoint] = []
    var focusedCueID: UUID? = nil
    var onDeselectFocus: (() -> Void)? = nil
    var onSelectCue: ((UUID) -> Void)? = nil
    @Binding var hoverInfo: RouteHoverInfo?
    var mapStyle: MapStyleOption

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = HoverMapView()
        let coordinator = context.coordinator
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        applyMapStyle(mapStyle, to: map)
        coordinator.appliedMapStyle = mapStyle
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

        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.appliedMapStyle != mapStyle {
            applyMapStyle(mapStyle, to: map)
            coordinator.appliedMapStyle = mapStyle
        }
        let signature = trackPoints.map { "\($0.lat),\($0.lon),\($0.cumKm)" }
        coordinator.trackPoints = trackPoints
        coordinator.hoverInfo = $hoverInfo
        coordinator.onDeselectFocus = onDeselectFocus
        coordinator.onSelectCue = onSelectCue

        if coordinator.builtPointSignature != signature {
            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations)
            coordinator.mainPolyline = nil
            coordinator.builtPointSignature = signature
            coordinator.highlightSignature = []
            coordinator.endpointAnnotations = []
            coordinator.cueAnnotations = []
            coordinator.hoverAnnotation = nil
            coordinator.hideTooltip()
            if hoverInfo != nil {
                let hoverBinding = $hoverInfo
                DispatchQueue.main.async {
                    hoverBinding.wrappedValue = nil
                }
            }

            guard trackPoints.count >= 2 else { return }

            let coords = trackPoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            let polyline = MKPolyline(coordinates: coords, count: coords.count)
            map.addOverlay(polyline, level: .aboveRoads)
            coordinator.mainPolyline = polyline
            let endpointAnnotations = [
                EndpointAnnotation(kind: .start, point: trackPoints[0]),
                EndpointAnnotation(kind: .end, point: trackPoints[trackPoints.count - 1]),
            ]
            coordinator.endpointAnnotations = endpointAnnotations
            map.addAnnotations(endpointAnnotations)

            let fitRect = polyline.boundingMapRect.insetBy(
                dx: -polyline.boundingMapRect.width * 0.1,
                dy: -polyline.boundingMapRect.height * 0.1
            )
            if map.frame.size == .zero {
                DispatchQueue.main.async { map.setVisibleMapRect(fitRect, animated: false) }
            } else {
                map.setVisibleMapRect(fitRect, animated: false)
            }
        }

        updateHighlight(map: map, coordinator: coordinator)
        updateCuePoints(map: map, coordinator: coordinator)
        coordinator.syncFocusedCue(in: map, focusedID: focusedCueID)
        coordinator.syncHoverPresentation(in: map, info: hoverInfo)
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
        var appliedMapStyle: MapStyleOption?
        var builtPointSignature: [String] = []
        var highlightSignature: [Double] = []
        var mainPolyline: MKPolyline?
        var highlightPolyline: HighlightPolyline?
        var endpointAnnotations: [EndpointAnnotation] = []
        var cueAnnotations: [CueAnnotation] = []
        var hoverAnnotation: HoverAnnotation?
        var trackPoints: [TrackPoint] = []
        var hoverInfo: Binding<RouteHoverInfo?>?
        var onDeselectFocus: (() -> Void)?
        var onSelectCue: ((UUID) -> Void)?
        var lastFocusedCueID: UUID?

        @objc func handleEmptyAreaClick(_ gesture: NSClickGestureRecognizer) {
            guard let map = gesture.view as? MKMapView, let superview = map.superview else { return }
            let pointInMap = gesture.location(in: map)
            let pointInSuper = map.convert(pointInMap, to: superview)
            // 클릭 지점에 annotation이 있으면 무시 (annotation 자체 선택은 MKMapView가 처리).
            var view = map.hitTest(pointInSuper)
            while let v = view {
                if v is MKAnnotationView { return }
                if v === map { break }
                view = v.superview
            }
            onDeselectFocus?()
        }

        private let hoverHitThreshold: CGFloat = 10
        private weak var tooltipView: NSVisualEffectView?
        private weak var tooltipLabel: NSTextField?
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
            showTooltip(in: map, at: point, info: info)
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

        func syncHoverPresentation(in map: MKMapView, info: RouteHoverInfo?) {
            guard let info else {
                mapMouseHoverActive = false
                removeHoverDot(in: map)
                hideTooltip()
                return
            }

            updateHoverDot(in: map, info: info)
            if !mapMouseHoverActive {
                showTooltipAtRoutePoint(in: map, info: info)
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

        private func showTooltipAtRoutePoint(in map: MKMapView, info: RouteHoverInfo) {
            let point = map.convert(
                CLLocationCoordinate2D(latitude: info.lat, longitude: info.lon),
                toPointTo: map
            )
            showTooltip(in: map, at: point, info: info)
        }

        func hideTooltip() {
            tooltipView?.isHidden = true
        }

        private func nearestProjection(
            in map: MKMapView,
            to point: CGPoint
        ) -> (segmentStartIndex: Int, fraction: Double, screenDistance: CGFloat)? {
            var best: (segmentStartIndex: Int, fraction: Double, screenDistance: CGFloat)?

            for i in 0..<(trackPoints.count - 1) {
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

        private func showTooltip(in map: MKMapView, at point: CGPoint, info: RouteHoverInfo) {
            let (bubble, label) = ensureTooltip(in: map)
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

        private func ensureTooltip(in map: MKMapView) -> (NSVisualEffectView, NSTextField) {
            if let tooltipView, let tooltipLabel {
                return (tooltipView, tooltipLabel)
            }

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
            tooltipView = bubble
            tooltipLabel = label
            return (bubble, label)
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let cue = view.annotation as? CueAnnotation else { return }
            // 같은 cue를 syncFocusedCue가 다시 select하는 경우는 콜백 발생을 피한다.
            if lastFocusedCueID == cue.cue.id { return }
            lastFocusedCueID = cue.cue.id
            onSelectCue?(cue.cue.id)
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            if polyline is HighlightPolyline {
                renderer.strokeColor = NSColor.systemCyan
                renderer.lineWidth = 5
            } else {
                renderer.strokeColor = NSColor.systemOrange
                renderer.lineWidth = 3
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

            if let endpoint = annotation as? EndpointAnnotation {
                let identifier = endpoint.kind == .start ? "routeStartPoint" : "routeEndPoint"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                let image = endpoint.kind == .start ? Self.startEndpointImage : Self.endEndpointImage
                v.annotation = annotation
                v.image = image
                v.centerOffset = CGPoint(x: 0, y: -image.size.height / 2)
                v.clusteringIdentifier = nil
                v.displayPriority = .required
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

        private static let hoverDotImage: NSImage = {
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
        }()

        private static let startEndpointImage = endpointLabelImage(text: "Start", color: .systemGreen)
        private static let endEndpointImage = endpointLabelImage(text: "End", color: .systemRed)

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
