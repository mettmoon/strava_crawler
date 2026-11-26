import Foundation
import CourseBoyKit

/// 고도가 없는 트랙포인트에 수치표고모델(DEM) 고도를 채운다.
///
/// OSRM 경로 응답에는 고도가 없어서 코스 그리기로 만든 구간은 고도 그래프가 비어 있다.
/// Open-Meteo Elevation API(Copernicus DEM GLO-90, 약 90m 해상도)로 일정 간격의 표본점만
/// 조회하고, 나머지 점은 거리 비례로 보간한다. 조회 결과는 약 11m 격자 단위로 메모리에 둔다.
actor ElevationService {
    static let shared = ElevationService()

    /// 한 요청에 넣을 수 있는 최대 좌표 수(Open-Meteo 제한).
    private let batchSize = 100
    /// 표본점 간격. DEM 해상도(90m)보다 촘촘하면 같은 셀을 반복 조회할 뿐이고,
    /// Open-Meteo 무료 한도는 좌표 1개를 호출 1번으로 세어 분당 약 600개라 아껴 써야 한다.
    private let sampleSpacingKm = 0.09

    private var cache: [GridKey: Double] = [:]

    /// 위경도 1e-4도(약 11m) 격자.
    private struct GridKey: Hashable {
        let lat: Int32
        let lon: Int32

        init(lat: Double, lon: Double) {
            self.lat = Int32((lat * 10_000).rounded())
            self.lon = Int32((lon * 10_000).rounded())
        }

        var latitude: Double { Double(lat) / 10_000 }
        var longitude: Double { Double(lon) / 10_000 }
    }

    /// 각 구간에서 `ele`가 nil인 점만 채운다. 이미 있는 고도는 건드리지 않는다.
    /// 조회에 실패한 구간은 nil을 돌려준다. 한도에 걸려도 앞 구간부터 채워지도록 순서대로 조회한다.
    func fillMissingElevations(_ segments: [[TrackPointCodable]]) async -> [[TrackPointCodable]?] {
        var results: [[TrackPointCodable]?] = []
        var failed = false
        for points in segments {
            let plan = samplePlan(for: points)
            if plan.isEmpty {
                results.append(points)
                continue
            }
            if !failed {
                var missing: [GridKey] = []
                var seen = Set<GridKey>()
                for sample in plan where cache[sample.key] == nil && seen.insert(sample.key).inserted {
                    missing.append(sample.key)
                }
                failed = !(await fetch(missing))
            }
            var samples: [(km: Double, ele: Double)] = []
            samples.reserveCapacity(plan.count)
            for sample in plan {
                guard let ele = cache[sample.key] else { break }
                samples.append((sample.km, ele))
            }
            results.append(samples.count == plan.count ? Self.interpolate(points, samples: samples) : nil)
        }
        return results
    }

    // MARK: - Private

    private struct Sample {
        let km: Double
        let key: GridKey
    }

    /// 고도를 채울 점이 있으면 처음·끝과 `sampleSpacingKm` 간격 표본을 고른다.
    private func samplePlan(for points: [TrackPointCodable]) -> [Sample] {
        guard points.contains(where: { $0.ele == nil }) else { return [] }
        var result: [Sample] = []
        var km = 0.0
        var lastSampleKm = -Double.infinity
        for (index, point) in points.enumerated() {
            if index > 0 {
                let prev = points[index - 1]
                km += Geo.haversineKm(prev.lat, prev.lon, point.lat, point.lon)
            }
            let isEdge = index == 0 || index == points.count - 1
            if isEdge || km - lastSampleKm >= sampleSpacingKm {
                result.append(Sample(km: km, key: GridKey(lat: point.lat, lon: point.lon)))
                lastSampleKm = km
            }
        }
        return result
    }

    /// 표본 고도를 거리 비례로 보간해 nil인 점만 채운다.
    private static func interpolate(
        _ points: [TrackPointCodable],
        samples: [(km: Double, ele: Double)]
    ) -> [TrackPointCodable] {
        guard !samples.isEmpty else { return points }
        var result = points
        var km = 0.0
        var cursor = 0
        for index in result.indices {
            if index > 0 {
                let prev = points[index - 1]
                km += Geo.haversineKm(prev.lat, prev.lon, points[index].lat, points[index].lon)
            }
            guard result[index].ele == nil else { continue }
            while cursor + 1 < samples.count && samples[cursor + 1].km < km {
                cursor += 1
            }
            let a = samples[cursor]
            guard cursor + 1 < samples.count else {
                result[index].ele = a.ele
                continue
            }
            let b = samples[cursor + 1]
            let span = b.km - a.km
            let t = span > 0 ? min(max((km - a.km) / span, 0), 1) : 0
            result[index].ele = a.ele + (b.ele - a.ele) * t
        }
        return result
    }

    /// 모두 받아 오면 true. 실패하면 그때까지 받은 것만 캐시에 남긴다.
    private func fetch(_ pending: [GridKey]) async -> Bool {
        for start in stride(from: 0, to: pending.count, by: batchSize) {
            if Task.isCancelled { return false }
            let batch = Array(pending[start..<min(start + batchSize, pending.count)])
            guard let elevations = await request(batch) else { return false }
            for (key, ele) in zip(batch, elevations) {
                cache[key] = ele
            }
        }
        return true
    }

    private func request(_ keys: [GridKey]) async -> [Double]? {
        let latitudes = keys.map { String(format: "%.4f", $0.latitude) }.joined(separator: ",")
        let longitudes = keys.map { String(format: "%.4f", $0.longitude) }.joined(separator: ",")
        var components = URLComponents(string: "https://api.open-meteo.com/v1/elevation")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: latitudes),
            URLQueryItem(name: "longitude", value: longitudes),
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            // 바다 등 DEM이 없는 곳은 NaN 대신 null이 올 수 있어 0m로 둔다.
            let elevations = decoded.elevation.map { $0 ?? 0 }
            return elevations.count == keys.count ? elevations : nil
        } catch {
            return nil
        }
    }

    private struct Response: Decodable {
        let elevation: [Double?]
    }
}

/// 편집 화면 고도 그래프 위에 띄우는 고도 채우기 상태.
enum ElevationFillStatus: Equatable {
    case loading
    /// 조회 한도 등으로 실패해 잠시 뒤 다시 시도한다.
    case failed
    /// 재시도도 실패했다. 경로를 다시 고치면 새로 시도한다.
    case gaveUp

    var message: String {
        switch self {
        case .loading: return "고도 불러오는 중…"
        case .failed: return "고도 조회 한도에 걸려 잠시 후 다시 시도합니다"
        case .gaveUp: return "고도를 불러오지 못했습니다"
        }
    }

    var symbol: String {
        switch self {
        case .loading: return "mountain.2"
        case .failed: return "clock.arrow.circlepath"
        case .gaveUp: return "exclamationmark.triangle"
        }
    }
}
