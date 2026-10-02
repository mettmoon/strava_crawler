import CoreLocation
import CoursePreviewCore
import MapKit
import Observation
import UIKit

/// 사용자의 현재 위치. 선택 지점(selectedProfilePoint)과 별개로 관리한다.
struct CourseCurrentLocation: Equatable {
    var lat: Double
    var lon: Double
    var horizontalAccuracy: CLLocationAccuracy
    /// 코스 위(허용 오차 이내)로 인식되면 코스에 스냅된 지점. 코스 밖이면 nil.
    var routeMatch: CourseProfileSelection?

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }
}

/// 내 위치 버튼의 트래킹 모드를 관리한다.
/// - off: 위치 업데이트 없음
/// - following: 위치 업데이트 + 지도가 내 위치를 따라감
/// - tracking: 위치 업데이트는 계속하지만 사용자가 지도를 움직여 따라가기가 해제된 상태
@Observable
final class CourseLocationTracker: NSObject, CLLocationManagerDelegate {
    enum Mode: Equatable {
        case off
        case following
        case tracking
    }

    static let routeToleranceMeters: CLLocationDistance = 50

    private(set) var mode: Mode = .off
    private(set) var currentLocation: CourseCurrentLocation?
    /// 마지막으로 코스 위에서 인식된 지점. 코스를 벗어나도 유지해서 이탈 지점 표시와 복귀 시 구간 연속성에 쓴다.
    private(set) var lastRouteMatch: CourseProfileSelection?
    var showsAuthorizationDeniedAlert = false

    /// 위치는 받고 있지만 코스 허용 오차 밖에 있는 상태.
    var isOffRoute: Bool {
        currentLocation != nil && currentLocation?.routeMatch == nil
    }

    @ObservationIgnored private var trackPoints: [TrackPoint] = []
    @ObservationIgnored private lazy var manager: CLLocationManager = {
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 3
        manager.activityType = .fitness
        return manager
    }()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.mode != .off else { return }
            self.manager.stopUpdatingLocation()
        })
        observers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.mode != .off else { return }
            self.manager.startUpdatingLocation()
        })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
        if mode != .off {
            manager.stopUpdatingLocation()
        }
    }

    /// 내 위치 버튼: off → following, tracking → following, following → off.
    func toggle(course: LoadedCourse) {
        switch mode {
        case .off:
            start(course: course)
        case .tracking:
            mode = .following
        case .following:
            stop()
        }
    }

    /// 사용자가 지도를 직접 움직여 따라가기가 풀렸을 때 호출한다. 위치 업데이트는 유지한다.
    func stopFollowing() {
        guard mode == .following else { return }
        mode = .tracking
    }

    func stop() {
        guard mode != .off else { return }
        mode = .off
        currentLocation = nil
        lastRouteMatch = nil
        manager.stopUpdatingLocation()
    }

    private func start(course: LoadedCourse) {
        trackPoints = course.trackPoints
        switch manager.authorizationStatus {
        case .denied, .restricted:
            showsAuthorizationDeniedAlert = true
            return
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            break
        @unknown default:
            break
        }
        mode = .following
        manager.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .denied, .restricted:
            if mode != .off {
                stop()
                showsAuthorizationDeniedAlert = true
            }
        case .authorizedAlways, .authorizedWhenInUse:
            if mode != .off {
                manager.startUpdatingLocation()
            }
        case .notDetermined:
            break
        @unknown default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard mode != .off,
              let location = locations.last,
              location.horizontalAccuracy >= 0 else {
            return
        }
        let match = CourseRouteLocationMatcher.match(
            coordinate: location.coordinate,
            trackPoints: trackPoints,
            toleranceMeters: Self.routeToleranceMeters,
            preferredDistanceKm: lastRouteMatch?.distanceKm
        )
        if let match {
            lastRouteMatch = match.selection
        }
        currentLocation = CourseCurrentLocation(
            lat: location.coordinate.latitude,
            lon: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            routeMatch: match?.selection
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 일시적인 실패(kCLErrorLocationUnknown)는 무시하고 다음 업데이트를 기다린다.
        if (error as? CLError)?.code == .denied {
            stop()
            showsAuthorizationDeniedAlert = true
        }
    }
}

struct CourseRouteLocationMatch {
    var selection: CourseProfileSelection
    var distanceFromRouteMeters: CLLocationDistance
}

enum CourseRouteLocationMatcher {
    /// 직전 지점에서 이 거리(km) 이상 떨어진 후보에는 벌점을 줘서,
    /// 왕복 구간처럼 코스가 겹칠 때 진행 중인 쪽 구간을 유지한다.
    private static let continuityWindowKm = 1.0
    private static let continuityPenaltyMeters: CLLocationDistance = 1_000

    static func match(
        coordinate: CLLocationCoordinate2D,
        trackPoints: [TrackPoint],
        toleranceMeters: CLLocationDistance,
        preferredDistanceKm: Double? = nil
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
        var bestScore = CLLocationDistance.infinity

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

            let distanceKm = startPoint.cumKm + (endPoint.cumKm - startPoint.cumKm) * ratio
            var score = distance
            if let preferredDistanceKm, abs(distanceKm - preferredDistanceKm) > continuityWindowKm {
                score += continuityPenaltyMeters
            }
            guard score < bestScore else { continue }
            bestScore = score

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
