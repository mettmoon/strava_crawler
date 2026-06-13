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

    /// 키워드로 카카오 로컬 검색. rect는 화면에 보이는 MKMapRect를 그대로 사용 — 카카오 API의 `rect`
    /// 파라미터(좌하단·우상단)로 전달해 화면 사각형 안에서만 검색한다.
    static func search(query: String, in rect: MKMapRect) async throws -> [KakaoLocalResult] {
        guard !apiKey.isEmpty, apiKey != "YOUR_KAKAO_REST_API_KEY" else {
            throw SearchError.noAPIKey
        }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        // MKMapRect는 y축이 반전(minY=북, maxY=남)이므로
        // 좌하단(SW) = (minX, maxY), 우상단(NE) = (maxX, minY)
        let sw = MKMapPoint(x: rect.minX, y: rect.maxY).coordinate
        let ne = MKMapPoint(x: rect.maxX, y: rect.minY).coordinate
        let rectParam = "\(sw.longitude),\(sw.latitude),\(ne.longitude),\(ne.latitude)"

        var comps = URLComponents(string: "https://dapi.kakao.com/v2/local/search/keyword.json")!
        comps.queryItems = [
            .init(name: "query", value: query),
            .init(name: "rect",  value: rectParam),
            .init(name: "size",  value: "15"),
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

// MARK: - GoogleMapsLink

enum GoogleMapsLink {
    /// 구글 맵 웹 URL (해당 좌표 검색/표시)
    static func webURL(lat: Double, lon: Double) -> URL {
        var comps = URLComponents(string: "https://www.google.com/maps/search/")!
        comps.queryItems = [
            .init(name: "api", value: "1"),
            .init(name: "query", value: "\(lat),\(lon)"),
        ]
        return comps.url!
    }

    /// 구글 맵 로드뷰(Street View) URL
    static func roadviewURL(lat: Double, lon: Double) -> URL {
        var comps = URLComponents(string: "https://www.google.com/maps/@")!
        comps.queryItems = [
            .init(name: "api", value: "1"),
            .init(name: "map_action", value: "pano"),
            .init(name: "viewpoint", value: "\(lat),\(lon)"),
        ]
        return comps.url!
    }
}
