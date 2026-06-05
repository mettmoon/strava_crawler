import Foundation
import MapKit
import StravaTCXKit

// MARK: - KakaoLocalResult

struct KakaoLocalResult: Identifiable, Sendable {
    let id: String
    let name: String
    let category: String
    let address: String
    let lat: Double
    let lon: Double
}

// MARK: - KakaoLocalSearch

enum KakaoLocalSearch {
    private static var apiKey: String {
        Bundle.main.infoDictionary?["KakaoLocalAPIKey"] as? String ?? ""
    }

    /// 키워드로 카카오 로컬 검색. rect는 화면에 보이는 MKMapRect (검색 중심/반경 계산에 사용).
    static func search(query: String, in rect: MKMapRect) async throws -> [KakaoLocalResult] {
        guard !apiKey.isEmpty, apiKey != "YOUR_KAKAO_REST_API_KEY" else {
            throw SearchError.noAPIKey
        }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        // rect 중심 좌표
        let centerMapPt = MKMapPoint(x: rect.midX, y: rect.midY)
        let center = centerMapPt.coordinate

        // rect 대각선 절반 = 검색 반경 (최대 20000m)
        let ne = MKMapPoint(x: rect.maxX, y: rect.minY).coordinate
        let sw = MKMapPoint(x: rect.minX, y: rect.maxY).coordinate
        let radiusM = min(Geo.haversineKm(center.latitude, center.longitude,
                                          ne.latitude, ne.longitude) * 1000, 20000)

        var comps = URLComponents(string: "https://dapi.kakao.com/v2/local/search/keyword.json")!
        comps.queryItems = [
            .init(name: "query",  value: query),
            .init(name: "x",      value: "\(center.longitude)"),
            .init(name: "y",      value: "\(center.latitude)"),
            .init(name: "radius", value: "\(Int(radiusM))"),
            .init(name: "size",   value: "15"),
        ]
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion
        let headers: [String: String] = [
            "Authorization": "KakaoAK \(apiKey)",
            "KA": "sdk/1.0 os/macos-\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion) lang/ko",
        ]
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = headers
        let session = URLSession(configuration: config)

        let req = URLRequest(url: comps.url!)
        print("[KakaoSearch] 요청 URL: \(comps.url!)")
        print("[KakaoSearch] 요청 헤더: \(headers)")

        let (data, resp) = try await session.data(for: req)
        let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
        print("[KakaoSearch] 응답 status=\(statusCode), body=\(String(data: data, encoding: .utf8)?.prefix(300) ?? "-")")
        guard statusCode == 200 else {
            throw SearchError.httpError(statusCode)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let docs = json["documents"] as? [[String: Any]] else { return [] }

        return docs.compactMap { d -> KakaoLocalResult? in
            guard let id   = d["id"] as? String,
                  let name = d["place_name"] as? String,
                  let xStr = d["x"] as? String, let lon = Double(xStr),
                  let yStr = d["y"] as? String, let lat = Double(yStr) else { return nil }
            let category = d["category_name"] as? String ?? ""
            let address  = (d["road_address_name"] as? String)
                        ?? (d["address_name"] as? String) ?? ""
            return KakaoLocalResult(id: id, name: name, category: category,
                                    address: address, lat: lat, lon: lon)
        }
    }

    /// 카카오맵 웹 URL (해당 좌표 중심)
    static func webURL(lat: Double, lon: Double) -> URL {
        URL(string: "https://map.kakao.com/link/map/\(lat),\(lon)")!
    }

    /// 카카오맵 로드뷰 URL
    static func roadvewURL(lat: Double, lon: Double) -> URL {
        URL(string: "https://map.kakao.com/link/roadview/\(lat),\(lon)")!
    }

    enum SearchError: LocalizedError {
        case noAPIKey
        case httpError(Int)
        var errorDescription: String? {
            switch self {
            case .noAPIKey:        return "카카오 API 키가 설정되지 않았습니다."
            case .httpError(let c): return "카카오 API 오류 (\(c))"
            }
        }
    }
}
