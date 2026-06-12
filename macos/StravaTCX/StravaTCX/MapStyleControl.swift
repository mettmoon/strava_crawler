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

    func makeConfiguration() -> MKMapConfiguration {
        switch self {
        case .standard: return MKStandardMapConfiguration(elevationStyle: .realistic)
        case .hybrid:   return MKHybridMapConfiguration(elevationStyle: .realistic)
        case .imagery:  return MKImageryMapConfiguration(elevationStyle: .realistic)
        }
    }
}

/// AppStorage에서 공유하는 지도 스타일 키.
enum MapStyleStorageKey {
    static let main = "mapStyle.main"
    static let editor = "mapStyle.editor"
}

/// MKMapView에 선택한 스타일을 적용한다.
func applyMapStyle(_ style: MapStyleOption, to map: MKMapView) {
    map.preferredConfiguration = style.makeConfiguration()
}

/// 지도 우상단에 띄우는 스타일 전환 메뉴. 부모 ZStack 위에 overlay로 사용한다.
struct MapStylePicker: View {
    @Binding var selection: MapStyleOption

    var body: some View {
        Menu {
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
