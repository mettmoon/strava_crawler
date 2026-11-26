import SwiftUI
import MapKit

/// 지도 스타일 옵션. MapKit이 제공하는 표준 / 하이브리드 / 위성 모드를 감싼다.
enum MapStyleOption: String, CaseIterable, Identifiable {
    case standard
    case hybrid
    case imagery

    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: return "표준"
        case .hybrid:   return "하이브리드"
        case .imagery:  return "위성"
        }
    }

    var symbol: String {
        switch self {
        case .standard: return "map"
        case .hybrid:   return "globe.americas.fill"
        case .imagery:  return "globe"
        }
    }

    /// - Parameter flat: 지형 기복을 끈다. 평면인 지도 파일을 덮을 때 쓴다.
    func makeConfiguration(flat: Bool = false) -> MKMapConfiguration {
        let elevation: MKMapConfiguration.ElevationStyle = flat ? .flat : .realistic
        switch self {
        case .standard: return MKStandardMapConfiguration(elevationStyle: elevation)
        case .hybrid:   return MKHybridMapConfiguration(elevationStyle: elevation)
        case .imagery:  return MKImageryMapConfiguration(elevationStyle: elevation)
        }
    }
}

/// AppStorage에서 공유하는 지도 스타일 키.
enum MapStyleStorageKey {
    static let main = "mapStyle.main"
    static let editor = "mapStyle.editor"
}

/// MKMapView에 선택한 스타일을 적용한다.
/// - Parameter flat: 지도 파일 오버레이를 덮은 동안에는 지형 기복을 끈다.
func applyMapStyle(_ style: MapStyleOption, to map: MKMapView, flat: Bool = false) {
    map.preferredConfiguration = style.makeConfiguration(flat: flat)
}

/// 지도에 마지막으로 적용한 스타일. 같은 값이면 다시 적용하지 않는다.
struct AppliedMapStyle: Equatable {
    var style: MapStyleOption
    var flat: Bool
}

/// 지도 우상단에 띄우는 스타일 전환 메뉴. 부모 ZStack 위에 overlay로 사용한다.
struct MapStylePicker: View {
    @Binding var selection: MapStyleOption
    /// 있으면 '경로 색' 섹션을 보여준다. 노면 정보가 있는 코스에서만 넘긴다.
    var routeColor: Binding<RouteColorMode>? = nil

    var body: some View {
        Menu {
            Section("지도") {
                ForEach(MapStyleOption.allCases) { option in
                    Button {
                        selection = option
                    } label: {
                        if option == selection {
                            Label(option.label, systemImage: "checkmark")
                        } else {
                            Text(option.label)
                        }
                    }
                }
            }
            MapOverlayMenuSection()
            if let routeColor {
                Section("경로 색") {
                    ForEach(RouteColorMode.allCases) { mode in
                        Button {
                            routeColor.wrappedValue = mode
                        } label: {
                            if mode == routeColor.wrappedValue {
                                Label(mode.label, systemImage: "checkmark")
                            } else {
                                Text(mode.label)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "map")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .help("지도 종류")
    }
}
