import MapKit
import SwiftUI

struct CourseLocateRequest: Equatable {
    var id = UUID()
}

struct CourseMapView: UIViewRepresentable {
    let course: LoadedCourse
    @Binding var selectedCueID: UUID?
    @Binding var selectedProfilePoint: CourseProfileSelection?
    @Binding var locateRequest: CourseLocateRequest?

    func makeCoordinator() -> Coordinator {
        Coordinator(
            selectedCueID: $selectedCueID,
            selectedProfilePoint: $selectedProfilePoint
        )
    }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        map.pointOfInterestFilter = .excludingAll
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.selectedCueID = $selectedCueID
        context.coordinator.selectedProfilePoint = $selectedProfilePoint
        context.coordinator.syncCourse(course, in: map)
        context.coordinator.syncLocateRequest(locateRequest, course: course, in: map)
        context.coordinator.syncSelectedCue(selectedCueID, in: map)
        context.coordinator.syncProfileSelection(selectedProfilePoint, in: map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, CLLocationManagerDelegate {
        var selectedCueID: Binding<UUID?>
        var selectedProfilePoint: Binding<CourseProfileSelection?>
        private var loadedCourseID: UUID?
        private var cueAnnotations: [CourseCueAnnotation] = []
        private var profileSelectionAnnotation: CourseProfileSelectionAnnotation?
        private let locationManager = CLLocationManager()
        private weak var pendingLocationMap: MKMapView?
        private var pendingLocationCourse: LoadedCourse?
        private var handledLocateRequestID: UUID?

        init(
            selectedCueID: Binding<UUID?>,
            selectedProfilePoint: Binding<CourseProfileSelection?>
        ) {
            self.selectedCueID = selectedCueID
            self.selectedProfilePoint = selectedProfilePoint
            super.init()
            locationManager.delegate = self
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.distanceFilter = kCLDistanceFilterNone
        }

        func syncCourse(_ course: LoadedCourse, in map: MKMapView) {
            guard loadedCourseID != course.id else { return }
            loadedCourseID = course.id
            cueAnnotations = []
            profileSelectionAnnotation = nil

            map.removeOverlays(map.overlays)
            map.removeAnnotations(map.annotations)

            let coordinates = course.trackPoints.map(\.coordinate)
            if coordinates.count >= 2 {
                let route = CourseRoutePolyline(coordinates: coordinates, count: coordinates.count)
                map.addOverlay(route, level: .aboveRoads)

                let rect = paddedRect(for: route.boundingMapRect)
                if map.bounds.size == .zero {
                    DispatchQueue.main.async {
                        map.setVisibleMapRect(rect, animated: false)
                    }
                } else {
                    map.setVisibleMapRect(rect, animated: false)
                }
            }

            if let first = course.trackPoints.first {
                map.addAnnotation(CourseEndpointAnnotation(kind: .start, point: first))
            }
            if let last = course.trackPoints.last {
                map.addAnnotation(CourseEndpointAnnotation(kind: .end, point: last))
            }

            cueAnnotations = course.sortedCuePoints.map(CourseCueAnnotation.init)
            map.addAnnotations(cueAnnotations)
        }

        func syncLocateRequest(_ request: CourseLocateRequest?, course: LoadedCourse, in map: MKMapView) {
            guard let request, handledLocateRequestID != request.id else { return }
            handledLocateRequestID = request.id
            pendingLocationMap = map
            pendingLocationCourse = course
            map.showsUserLocation = true

            switch locationManager.authorizationStatus {
            case .notDetermined:
                locationManager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                requestCurrentLocation()
            case .denied, .restricted:
                centerMapOnKnownUserLocation(in: map, course: course)
            @unknown default:
                break
            }
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
            map.setCenter(annotation.coordinate, animated: true)
        }

        func syncProfileSelection(_ selection: CourseProfileSelection?, in map: MKMapView) {
            guard let selection else {
                if let profileSelectionAnnotation {
                    map.removeAnnotation(profileSelectionAnnotation)
                    self.profileSelectionAnnotation = nil
                }
                return
            }

            if let annotation = profileSelectionAnnotation {
                annotation.update(selection: selection)
            } else {
                let annotation = CourseProfileSelectionAnnotation(selection: selection)
                profileSelectionAnnotation = annotation
                map.addAnnotation(annotation)
            }

            if selectedCueID.wrappedValue == nil {
                map.setCenter(selection.coordinate, animated: true)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if overlay is CourseRoutePolyline {
                let renderer = MKPolylineRenderer(overlay: overlay)
                renderer.strokeColor = UIColor.systemBlue
                renderer.lineWidth = 4
                renderer.lineJoin = .round
                renderer.lineCap = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
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
                view.displayPriority = .defaultHigh
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
            guard let cue = view.annotation as? CourseCueAnnotation else { return }
            selectedProfilePoint.wrappedValue = nil
            selectedCueID.wrappedValue = cue.cue.id
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard view.annotation is CourseCueAnnotation else { return }
            if mapView.selectedAnnotations.compactMap({ $0 as? CourseCueAnnotation }).isEmpty {
                selectedCueID.wrappedValue = nil
            }
        }

        func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                requestCurrentLocation()
            case .denied, .restricted:
                pendingLocationMap = nil
                pendingLocationCourse = nil
            case .notDetermined:
                break
            @unknown default:
                break
            }
        }

        func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
            guard let location = locations.last,
                  let map = pendingLocationMap,
                  let course = pendingLocationCourse else {
                return
            }
            applyCurrentLocation(location, in: map, course: course)
        }

        func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
            if let map = pendingLocationMap, let course = pendingLocationCourse {
                centerMapOnKnownUserLocation(in: map, course: course)
            }
            pendingLocationMap = nil
            pendingLocationCourse = nil
        }

        private func requestCurrentLocation() {
            if let map = pendingLocationMap,
               let course = pendingLocationCourse,
               let location = map.userLocation.location {
                applyCurrentLocation(location, in: map, course: course)
                return
            }
            locationManager.requestLocation()
        }

        private func centerMapOnKnownUserLocation(in map: MKMapView, course: LoadedCourse) {
            guard let location = map.userLocation.location else { return }
            applyCurrentLocation(location, in: map, course: course)
        }

        private func applyCurrentLocation(_ location: CLLocation, in map: MKMapView, course: LoadedCourse) {
            let coordinate = location.coordinate
            let region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: 700,
                longitudinalMeters: 700
            )
            map.setRegion(region, animated: true)

            if let match = CourseRouteLocationMatcher.match(
                coordinate: coordinate,
                trackPoints: course.trackPoints,
                toleranceMeters: 50
            ) {
                selectedCueID.wrappedValue = nil
                selectedProfilePoint.wrappedValue = match.selection
            }

            pendingLocationMap = nil
            pendingLocationCourse = nil
        }

        private func paddedRect(for rect: MKMapRect) -> MKMapRect {
            let paddingX = max(rect.width * 0.12, 1200)
            let paddingY = max(rect.height * 0.12, 1200)
            return rect.insetBy(dx: -paddingX, dy: -paddingY)
        }
    }
}

private final class CourseRoutePolyline: MKPolyline {}

private struct CourseRouteLocationMatch {
    var selection: CourseProfileSelection
    var distanceFromRouteMeters: CLLocationDistance
}

private enum CourseRouteLocationMatcher {
    static func match(
        coordinate: CLLocationCoordinate2D,
        trackPoints: [TrackPoint],
        toleranceMeters: CLLocationDistance
    ) -> CourseRouteLocationMatch? {
        guard !trackPoints.isEmpty else { return nil }

        if trackPoints.count == 1 {
            let point = trackPoints[0]
            let distance = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(latitude: point.lat, longitude: point.lon))
            guard distance <= toleranceMeters else { return nil }
            return CourseRouteLocationMatch(
                selection: CourseProfileSelection(trackIndex: 0, point: point),
                distanceFromRouteMeters: distance
            )
        }

        let target = MKMapPoint(coordinate)
        var bestMatch: CourseRouteLocationMatch?

        for index in 0..<(trackPoints.count - 1) {
            let startPoint = trackPoints[index]
            let endPoint = trackPoints[index + 1]
            let start = MKMapPoint(startPoint.coordinate)
            let end = MKMapPoint(endPoint.coordinate)
            let dx = end.x - start.x
            let dy = end.y - start.y
            let segmentLengthSquared = dx * dx + dy * dy
            let rawRatio = segmentLengthSquared > 0
                ? ((target.x - start.x) * dx + (target.y - start.y) * dy) / segmentLengthSquared
                : 0
            let ratio = min(max(rawRatio, 0), 1)
            let snappedPoint = MKMapPoint(
                x: start.x + dx * ratio,
                y: start.y + dy * ratio
            )
            let snappedCoordinate = snappedPoint.coordinate
            let distance = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                .distance(from: CLLocation(
                    latitude: snappedCoordinate.latitude,
                    longitude: snappedCoordinate.longitude
                ))

            guard distance <= toleranceMeters else { continue }
            if let bestMatch, bestMatch.distanceFromRouteMeters <= distance { continue }

            let distanceKm = startPoint.cumKm + (endPoint.cumKm - startPoint.cumKm) * ratio
            let elevation = interpolatedElevation(from: startPoint, to: endPoint, ratio: ratio)
            let trackIndex = ratio < 0.5 ? index : index + 1
            let selection = CourseProfileSelection(
                trackIndex: trackIndex,
                lat: snappedCoordinate.latitude,
                lon: snappedCoordinate.longitude,
                distanceKm: distanceKm,
                elevationMeters: elevation
            )
            bestMatch = CourseRouteLocationMatch(
                selection: selection,
                distanceFromRouteMeters: distance
            )
        }

        return bestMatch
    }

    private static func interpolatedElevation(
        from startPoint: TrackPoint,
        to endPoint: TrackPoint,
        ratio: Double
    ) -> Double? {
        switch (startPoint.ele, endPoint.ele) {
        case let (.some(start), .some(end)):
            return start + (end - start) * ratio
        case let (.some(start), .none):
            return start
        case let (.none, .some(end)):
            return end
        case (.none, .none):
            return nil
        }
    }
}

private final class CourseEndpointAnnotation: NSObject, MKAnnotation {
    enum Kind {
        case start
        case end
    }

    let kind: Kind
    let coordinate: CLLocationCoordinate2D
    let title: String?

    init(kind: Kind, point: TrackPoint) {
        self.kind = kind
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
