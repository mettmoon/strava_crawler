import MapKit
import SwiftUI

/// 지도 탭의 지도 종류. MapKit의 표준 / 하이브리드 / 위성 구성을 감싼다.
enum CourseMapStyle: String, CaseIterable, Identifiable {
    case standard
    case hybrid
    case imagery

    static let storageKey = "mapStyle"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "표준"
        case .hybrid: return "하이브리드"
        case .imagery: return "위성"
        }
    }

    var symbol: String {
        switch self {
        case .standard: return "map"
        case .hybrid: return "globe.asia.australia.fill"
        case .imagery: return "globe.asia.australia"
        }
    }

    func makeConfiguration() -> MKMapConfiguration {
        switch self {
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
