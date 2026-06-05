import SwiftUI
import MapKit
import StravaTCXKit

struct RouteMapView: NSViewRepresentable {
    let trackPoints: [TrackPoint]

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)
        guard trackPoints.count >= 2 else { return }

        // 경로 폴리라인
        let coords = trackPoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        let polyline = MKPolyline(coordinates: coords, count: coords.count)
        map.addOverlay(polyline, level: .aboveRoads)

        // 시작/종료 마커
        let start = MKPointAnnotation()
        start.coordinate = coords.first!
        start.title = "시작"
        let end = MKPointAnnotation()
        end.coordinate = coords.last!
        end.title = "종료"
        map.addAnnotations([start, end])

        // 경로 전체가 보이도록 지도 범위 설정
        // 처음 등장 시 frame이 아직 0일 수 있으므로 한 런루프 뒤에 적용
        let fitRect = polyline.boundingMapRect.insetBy(
            dx: -polyline.boundingMapRect.width * 0.1,
            dy: -polyline.boundingMapRect.height * 0.1
        )
        if map.frame.size == .zero {
            DispatchQueue.main.async {
                map.setVisibleMapRect(fitRect, animated: false)
            }
        } else {
            map.setVisibleMapRect(fitRect, animated: false)
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = NSColor.systemOrange
            renderer.lineWidth = 3
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
