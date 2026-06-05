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

struct RouteMapView: NSViewRepresentable {
    let trackPoints: [TrackPoint]
    var highlightPoints: [TrackPoint] = []
    var cuePoints: [CourseCuePoint] = []

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
            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations)
            coordinator.mainPolyline = nil
            coordinator.builtPointSignature = signature
            coordinator.cueAnnotations = []

            guard trackPoints.count >= 2 else { return }

            let coords = trackPoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            let polyline = MKPolyline(coordinates: coords, count: coords.count)
            map.addOverlay(polyline, level: .aboveRoads)
            coordinator.mainPolyline = polyline

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
    }

    // MARK: - 하이라이트 overlay만 교체

    private func updateHighlight(map: MKMapView, coordinator: Coordinator) {
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
        var builtPointSignature: [Double] = []
        var mainPolyline: MKPolyline?
        var highlightPolyline: HighlightPolyline?
        var cueAnnotations: [CueAnnotation] = []

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
    }
}
