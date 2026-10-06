import MapKit
import SwiftUI

/// 지도 탭의 지도 종류. MapKit의 표준 / 하이브리드 / 위성 구성과 OpenStreetMap 타일을 감싼다.
enum CourseMapStyle: String, CaseIterable, Identifiable {
    case standard
    case hybrid
    case imagery
    case openStreetMap
    case cyclOSM

    static let storageKey = "mapStyle"

    static let appleStyles: [CourseMapStyle] = [.standard, .hybrid, .imagery]
    static let tileStyles: [CourseMapStyle] = [.openStreetMap, .cyclOSM]

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "표준"
        case .hybrid: return "하이브리드"
        case .imagery: return "위성"
        case .openStreetMap: return "OpenStreetMap"
        case .cyclOSM: return "CyclOSM (자전거)"
        }
    }

    var symbol: String {
        switch self {
        case .standard: return "map"
        case .hybrid: return "globe.asia.australia.fill"
        case .imagery: return "globe.asia.australia"
        case .openStreetMap: return "map.fill"
        case .cyclOSM: return "bicycle"
        }
    }

    /// Apple 지도 대신 깔 타일 서버. Apple 지도 스타일이면 nil.
    var tileSource: CourseMapTileSource? {
        switch self {
        case .standard, .hybrid, .imagery: return nil
        case .openStreetMap: return .openStreetMap
        case .cyclOSM: return .cyclOSM
        }
    }

    func makeConfiguration() -> MKMapConfiguration {
        switch self {
        case .openStreetMap, .cyclOSM:
            // 타일이 바탕 지도를 덮으므로 가장 가벼운 평면 지도를 둔다. 위성 구성은 일정 줌 이상에서
            // 타일 오버레이를 그리지 않아 쓰지 않는다. 라벨은 타일을 라벨 위 레벨에 두어 가린다.
            let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
            configuration.pointOfInterestFilter = .excludingAll
            return configuration
        case .standard:
            let configuration = MKStandardMapConfiguration(elevationStyle: .realistic)
            configuration.pointOfInterestFilter = .excludingAll
            return configuration
        case .hybrid:
            let configuration = MKHybridMapConfiguration(elevationStyle: .realistic)
            configuration.pointOfInterestFilter = .excludingAll
            return configuration
        case .imagery:
            return MKImageryMapConfiguration(elevationStyle: .realistic)
        }
    }
}

/// 지도와 나침반 버튼은 서로 다른 representable에서 만들어지므로, 나중에 만들어진 쪽이 둘을 잇는다.
/// SwiftUI 상태가 아니어서 makeUIView에서 값을 넣어도 뷰 갱신을 일으키지 않는다.
final class CourseMapCompassLink {
    weak var mapView: MKMapView? {
        didSet { connect() }
    }

    weak var compassButton: MKCompassButton? {
        didSet { connect() }
    }

    private func connect() {
        compassButton?.mapView = mapView
    }
}

/// 지도가 회전했을 때만 나타나는 시스템 나침반 버튼. 누르면 북쪽을 위로 되돌리고 다시 숨는다.
struct CourseMapCompassButton: UIViewRepresentable {
    let link: CourseMapCompassLink

    func makeUIView(context: Context) -> MKCompassButton {
        let button = MKCompassButton(mapView: nil)
        button.compassVisibility = .adaptive
        link.compassButton = button
        return button
    }

    func updateUIView(_ button: MKCompassButton, context: Context) {
        if link.compassButton !== button {
            link.compassButton = button
        }
    }
}
