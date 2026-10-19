import Foundation

/// Quick Look 확장과 지도 스냅샷 XPC 서비스가 함께 쓰는 인터페이스.
/// Quick Look 샌드박스는 MapKit이 쓰는 GeoServices 캐시 접근을 막기 때문에,
/// 일반 앱 샌드박스로 실행되는 XPC 서비스에서 지도를 렌더링해 PNG로 돌려준다.
@objc(MapSnapshotServiceProtocol)
protocol MapSnapshotServiceProtocol {
    /// `requestData`는 JSON으로 인코딩한 `MapSnapshotRequest`.
    func makeSnapshot(requestData: Data, reply: @escaping (Data?, String?) -> Void)
}

enum MapSnapshotService {
    static let serviceName = "com.wejoapps.CourseBoy.QuickLookPreview.MapSnapshotService"
}

struct MapSnapshotRequest: Codable {
    struct Marker: Codable {
        enum Kind: String, Codable {
            case start
            case end
            case cue
        }

        let latitude: Double
        let longitude: Double
        let kind: Kind
        let pointType: String?
    }

    /// [위도, 경도] 쌍의 배열.
    let coordinates: [[Double]]
    let markers: [Marker]
    let width: Double
    let height: Double
    let isDark: Bool
}
