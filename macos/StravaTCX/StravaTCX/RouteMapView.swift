import SwiftUI
import MapKit
import StravaTCXKit

final class HighlightPolyline: MKPolyline {}

struct RouteMapView: NSViewRepresentable {
    let trackPoints: [TrackPoint]
    var highlightPoints: [TrackPoint] = []

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        let signature = trackPoints.map(\.cumKm)

        if coordinator.builtPointSignature != signature {
            // trackPoints 변경 → 전체 재구성
            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations)
            coordinator.mainPolyline = nil
            coordinator.builtPointSignature = signature

            guard trackPoints.count >= 2 else { return }

            let coords = trackPoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            let polyline = MKPolyline(coordinates: coords, count: coords.count)
            map.addOverlay(polyline, level: .aboveRoads)
            coordinator.mainPolyline = polyline

            let start = MKPointAnnotation()
            start.coordinate = coords.first!
            start.title = "시작"
            let end = MKPointAnnotation()
            end.coordinate = coords.last!
            end.title = "종료"
            coordinator.startAnnotation = start
            coordinator.endAnnotation = end
            map.addAnnotations([start, end])

            let fitRect = polyline.boundingMapRect.insetBy(
                dx: -polyline.boundingMapRect.width * 0.1,
                dy: -polyline.boundingMapRect.height * 0.1
            )
            // 처음 등장 시 frame이 아직 0일 수 있으므로 한 런루프 뒤에 적용
            if map.frame.size == .zero {
                DispatchQueue.main.async { map.setVisibleMapRect(fitRect, animated: false) }
            } else {
                map.setVisibleMapRect(fitRect, animated: false)
            }
        }

        updateHighlight(map: map, coordinator: coordinator)
    }

    // MARK: - 하이라이트 overlay/annotation만 교체

    private func updateHighlight(map: MKMapView, coordinator: Coordinator) {
        // 기존 하이라이트 제거
        if let hl = coordinator.highlightPolyline { map.removeOverlay(hl) }
        coordinator.highlightPolyline = nil
        if let a = coordinator.hlStartAnnotation { map.removeAnnotation(a) }
        if let a = coordinator.hlEndAnnotation   { map.removeAnnotation(a) }
        coordinator.hlStartAnnotation = nil
        coordinator.hlEndAnnotation   = nil

        guard highlightPoints.count >= 2 else {
            // 기본 마커 복구 (이미 있으면 스킵)
            let existingIDs = Set(map.annotations.map { ObjectIdentifier($0 as AnyObject) })
            if let s = coordinator.startAnnotation,
               !existingIDs.contains(ObjectIdentifier(s)) { map.addAnnotation(s) }
            if let e = coordinator.endAnnotation,
               !existingIDs.contains(ObjectIdentifier(e)) { map.addAnnotation(e) }
            return
        }

        // 기본 마커 숨기기
        if let s = coordinator.startAnnotation { map.removeAnnotation(s) }
        if let e = coordinator.endAnnotation   { map.removeAnnotation(e) }

        let hlCoords = highlightPoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        let hlPolyline = HighlightPolyline(coordinates: hlCoords, count: hlCoords.count)
        map.addOverlay(hlPolyline, level: .aboveRoads)
        coordinator.highlightPolyline = hlPolyline

        let hlStart = MKPointAnnotation()
        hlStart.coordinate = hlCoords.first!
        hlStart.title = "시작"
        let hlEnd = MKPointAnnotation()
        hlEnd.coordinate = hlCoords.last!
        hlEnd.title = "종료"
        coordinator.hlStartAnnotation = hlStart
        coordinator.hlEndAnnotation   = hlEnd
        map.addAnnotations([hlStart, hlEnd])
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var builtPointSignature: [Double] = []
        var mainPolyline: MKPolyline?
        var startAnnotation: MKPointAnnotation?
        var endAnnotation: MKPointAnnotation?
        var highlightPolyline: HighlightPolyline?
        var hlStartAnnotation: MKPointAnnotation?
        var hlEndAnnotation: MKPointAnnotation?

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
            guard let point = annotation as? MKPointAnnotation else { return nil }
            let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: nil)
            view.markerTintColor = point.title == "시작" ? .systemGreen : .systemRed
            view.glyphText = point.title == "시작" ? "S" : "E"
            return view
        }
    }
}
