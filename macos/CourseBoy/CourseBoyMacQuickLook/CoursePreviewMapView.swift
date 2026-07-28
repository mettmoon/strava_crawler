import CoursePreviewCore
import MapKit
import SwiftUI

struct CoursePreviewMapView: NSViewRepresentable {
    let course: LoadedCourse

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
        configuration.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = configuration
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        guard context.coordinator.loadedCourseID != course.id else { return }
        context.coordinator.loadedCourseID = course.id
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations)

        let coordinates = course.trackPoints.map(\.coordinate)
        if coordinates.count >= 2 {
            let polyline = MKPolyline(coordinates: coordinates, count: coordinates.count)
            map.addOverlay(polyline, level: .aboveRoads)
            map.setVisibleMapRect(
                polyline.boundingMapRect,
                edgePadding: NSEdgeInsets(top: 44, left: 44, bottom: 44, right: 44),
                animated: false
            )
        } else if let coordinate = coordinates.first {
            map.setRegion(
                MKCoordinateRegion(
                    center: coordinate,
                    latitudinalMeters: 1_000,
                    longitudinalMeters: 1_000
                ),
                animated: false
            )
        }

        if let first = course.trackPoints.first {
            map.addAnnotation(
                PreviewAnnotation(
                    coordinate: first.coordinate,
                    title: "시작점",
                    kind: .start
                )
            )
        }
        if course.trackPoints.count > 1, let last = course.trackPoints.last {
            map.addAnnotation(
                PreviewAnnotation(
                    coordinate: last.coordinate,
                    title: "종료점",
                    kind: .end
                )
            )
        }
        map.addAnnotations(course.sortedCuePoints.map {
            PreviewAnnotation(
                coordinate: $0.coordinate,
                title: $0.displayName,
                subtitle: formatRouteDistance($0.distanceKm),
                kind: .cue($0.pointType)
            )
        })
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var loadedCourseID: UUID?

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let polyline = overlay as? MKPolyline else {
                return MKOverlayRenderer(overlay: overlay)
            }
            let renderer = MKPolylineRenderer(polyline: polyline)
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = 4
            renderer.lineJoin = .round
            renderer.lineCap = .round
            return renderer
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let annotation = annotation as? PreviewAnnotation else { return nil }
            let identifier = "CoursePreviewAnnotation"
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: identifier)
            view.annotation = annotation
            view.canShowCallout = true

            switch annotation.kind {
            case .start:
                view.markerTintColor = NSColor.systemGreen
                view.glyphImage = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: "시작점")
            case .end:
                view.markerTintColor = NSColor.systemRed
                view.glyphImage = NSImage(
                    systemSymbolName: "flag.checkered",
                    accessibilityDescription: "종료점"
                )
            case .cue(let pointType):
                view.markerTintColor = markerColor(for: pointType)
                view.glyphImage = NSImage(
                    systemSymbolName: cueSymbolName(for: pointType),
                    accessibilityDescription: annotation.title
                )
            }
            return view
        }

        private func markerColor(for pointType: String) -> NSColor {
            switch pointType {
            case "Water": return .systemBlue
            case "Food": return .systemOrange
            case "Danger", "First Aid": return .systemRed
            case "Summit": return .systemGreen
            case "Left", "Right": return .systemPurple
            default: return .systemGray
            }
        }

        private func cueSymbolName(for pointType: String) -> String {
            switch pointType {
            case "Summit": return "mountain.2.fill"
            case "Water": return "drop.fill"
            case "Food": return "fork.knife"
            case "Danger": return "exclamationmark.triangle.fill"
            case "Left": return "arrow.turn.up.left"
            case "Right": return "arrow.turn.up.right"
            default: return "mappin"
            }
        }
    }
}

private final class PreviewAnnotation: NSObject, MKAnnotation {
    enum Kind {
        case start
        case end
        case cue(String)
    }

    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let kind: Kind

    init(
        coordinate: CLLocationCoordinate2D,
        title: String?,
        subtitle: String? = nil,
        kind: Kind
    ) {
        self.coordinate = coordinate
        self.title = title
        self.subtitle = subtitle
        self.kind = kind
    }
}
