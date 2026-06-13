import Foundation
import StravaTCXKit

/// OSRM route service 의 profile 경로 값.
enum OSRMRouteProfile: String, CaseIterable, Identifiable, Sendable {
    case driving
    case cycling
    case walking

    var id: String { rawValue }

    var label: String {
        switch self {
        case .driving: return "자동차"
        case .cycling: return "자전거"
        case .walking: return "도보"
        }
    }

    var symbol: String {
        switch self {
        case .driving: return "car.fill"
        case .cycling: return "bicycle"
        case .walking: return "figure.walk"
        }
    }

    static let defaultProfile: OSRMRouteProfile = .cycling
}

enum RouteProfileStorageKey {
    static let editor = "routeProfile.editor"
}

/// OSRM 공개 API로 두 지점 간 경로를 계산한다.
/// 결과는 메모리 캐시에 저장해 같은 구간 재요청을 방지한다.
actor OSRMRouter {
    static let shared = OSRMRouter()

    private var cache: [CacheKey: [TrackPointCodable]] = [:]

    private struct CacheKey: Hashable {
        let profile: OSRMRouteProfile
        let lat1: Double; let lon1: Double
        let lat2: Double; let lon2: Double
    }

    // MARK: - Public

    /// (start) → (end) 구간의 트랙포인트 배열을 반환한다.
    /// API 실패 시 start-end 직선 두 점으로 fallback.
    func route(
        from start: CourseRoutePoint,
        to end: CourseRoutePoint,
        profile: OSRMRouteProfile = .defaultProfile
    ) async -> [TrackPointCodable] {
        let key = CacheKey(profile: profile, lat1: start.lat, lon1: start.lon, lat2: end.lat, lon2: end.lon)
        if let cached = cache[key] { return cached }

        let result = await fetchOSRM(
            lat1: start.lat,
            lon1: start.lon,
            lat2: end.lat,
            lon2: end.lon,
            profile: profile
        )
        cache[key] = result
        return result
    }

    /// 캐시에서 특정 구간 제거 (RoutePoint 이동/삭제 후 호출).
    func invalidate(from start: CourseRoutePoint, to end: CourseRoutePoint) {
        let staleKeys = cache.keys.filter {
            $0.lat1 == start.lat && $0.lon1 == start.lon && $0.lat2 == end.lat && $0.lon2 == end.lon
        }
        for key in staleKeys {
            cache.removeValue(forKey: key)
        }
    }

    // MARK: - Private

    private func fetchOSRM(
        lat1: Double,
        lon1: Double,
        lat2: Double,
        lon2: Double,
        profile: OSRMRouteProfile
    ) async -> [TrackPointCodable] {
        // OSRM API: /route/v1/{profile}/{lon1},{lat1};{lon2},{lat2}
        let urlStr = "https://router.project-osrm.org/route/v1/\(profile.rawValue)/\(lon1),\(lat1);\(lon2),\(lat2)?geometries=geojson&overview=full"
        guard let url = URL(string: urlStr) else { return fallback(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2) }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return parse(data: data) ?? fallback(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)
        } catch {
            return fallback(lat1: lat1, lon1: lon1, lat2: lat2, lon2: lon2)
        }
    }

    private func parse(data: Data) -> [TrackPointCodable]? {
        guard let json = try? JSONSerialization.jsonObject(data: data) as? [String: Any],
              let routes = json["routes"] as? [[String: Any]],
              let first = routes.first,
              let geometry = first["geometry"] as? [String: Any],
              let coords = geometry["coordinates"] as? [[Double]],
              !coords.isEmpty else { return nil }

        var result: [TrackPointCodable] = []
        var cumKm: Double = 0
        for (i, coord) in coords.enumerated() {
            guard coord.count >= 2 else { continue }
            let lon = coord[0], lat = coord[1]
            let ele: Double? = coord.count >= 3 ? coord[2] : nil
            if i > 0 {
                let prev = coords[i - 1]
                cumKm += Geo.haversineKm(prev[1], prev[0], lat, lon)
            }
            let tp = TrackPoint(lat: lat, lon: lon, ele: ele, time: nil, cumKm: cumKm)
            result.append(TrackPointCodable(tp))
        }
        return result.isEmpty ? nil : result
    }

    private func fallback(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> [TrackPointCodable] {
        let dist = Geo.haversineKm(lat1, lon1, lat2, lon2)
        let p1 = TrackPoint(lat: lat1, lon: lon1, ele: nil, time: nil, cumKm: 0)
        let p2 = TrackPoint(lat: lat2, lon: lon2, ele: nil, time: nil, cumKm: dist)
        return [TrackPointCodable(p1), TrackPointCodable(p2)]
    }
}

private extension JSONSerialization {
    static func jsonObject(data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data)
    }
}
