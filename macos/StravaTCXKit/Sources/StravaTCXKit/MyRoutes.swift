import Foundation

/// 내 라우트 목록 1건.
public struct MyRoute: Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var distanceText: String?
    public var elevationText: String?
    public var thumbnailURL: URL?

    public init(id: String, name: String, distanceText: String? = nil,
                elevationText: String? = nil, thumbnailURL: URL? = nil) {
        self.id = id
        self.name = name
        self.distanceText = distanceText
        self.elevationText = elevationText
        self.thumbnailURL = thumbnailURL
    }
}

public struct MyRoutesPage: Sendable {
    public var routes: [MyRoute]
    public var hasMore: Bool
    public var nextAfter: String?   // 다음 페이지 after 커서 (pageInfo.endCursor+1)
    public init(routes: [MyRoute], hasMore: Bool, nextAfter: String? = nil) {
        self.routes = routes
        self.hasMore = hasMore
        self.nextAfter = nextAfter
    }
}

/// /api/next/data/routes/my-routes 요청 본문 생성 + 응답 파싱 (스키마 방어적).
public enum MyRoutesParser {

    static let allRouteTypes = [
        "Ride", "Run", "Walk", "Hike", "TrailRun", "GravelRide", "MountainBikeRide",
        "EMountainBikeRide", "EBikeRide", "Swim", "Kayak", "Golf", "Sail", "Canoe",
        "AlpineSki", "BackcountrySki", "IceSkate", "InlineSkate", "Handcycle", "Kitesurf",
        "NordicSki", "RockClimbing", "RollerSki", "Rowing", "Skateboard", "Snowshoe",
        "StandUpPaddle", "Surfing", "Velomobile", "Windsurf", "Wheelchair",
    ]

    public static func requestBody(after: String, pageSize: Int) -> Data {
        let searchArgs: [String: Any] = [
            "query": "",
            "onlyStarred": false,
            "createdBy": "Any",
            "routeTypes": allRouteTypes,
            "elevGainMin": 0,
            "elevGainMax": NSNull(),
            "distanceMin": 0,
            "distanceMax": NSNull(),
        ]
        let body: [String: Any] = [
            "pageSize": pageSize,
            "after": after,
            "searchArgs": searchArgs,
            "resolutions": [["height": 192, "width": 280, "isRetina": true]],
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
    }

    /// HTML 에서 csrf-token meta 추출.
    public static func extractCSRF(html: String) -> String? {
        let patterns = [
            #"<meta\s+name=\"csrf-token\"\s+content=\"([^\"]+)\""#,
            #"<meta\s+content=\"([^\"]+)\"\s+name=\"csrf-token\""#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
               let r = Range(m.range(at: 1), in: html) {
                return String(html[r])
            }
        }
        return nil
    }

    public static func parse(_ data: Data, pageSize: Int) -> MyRoutesPage {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            return MyRoutesPage(routes: [], hasMore: false)
        }
        let arr = findRoutesArray(obj) ?? []
        let routes = arr.compactMap(route(from:))

        // pageInfo (Relay): hasNextPage + endCursor → 다음 after = endCursor+1
        let pageInfo = findPageInfo(obj)
        let hasNext: Bool?
        if let b = pageInfo?["hasNextPage"] as? Bool { hasNext = b }
        else if let n = pageInfo?["hasNextPage"] as? NSNumber { hasNext = n.boolValue }
        else { hasNext = nil }
        var nextAfter: String?
        if let end = pageInfo?["endCursor"] as? String, let n = Int(end) {
            nextAfter = String(n + 1)
        }
        let hasMore = hasNext ?? (routes.count >= pageSize)
        return MyRoutesPage(routes: routes, hasMore: hasMore, nextAfter: nextAfter)
    }

    /// pageInfo dict 를 재귀 탐색.
    static func findPageInfo(_ obj: Any) -> [String: Any]? {
        if let d = obj as? [String: Any] {
            if let p = d["pageInfo"] as? [String: Any] { return p }
            if d["hasNextPage"] != nil || d["endCursor"] != nil { return d }
            for (_, v) in d {
                if let found = findPageInfo(v) { return found }
            }
        }
        if let a = obj as? [Any] {
            for v in a {
                if let found = findPageInfo(v) { return found }
            }
        }
        return nil
    }

    // MARK: - 내부

    /// id/id_str 를 가진 dict 들의 배열을 재귀적으로 탐색.
    static func findRoutesArray(_ obj: Any) -> [[String: Any]]? {
        if let arr = obj as? [[String: Any]],
           arr.contains(where: { $0["id"] != nil || $0["id_str"] != nil }) {
            return arr
        }
        if let dict = obj as? [String: Any] {
            for key in ["nodes", "searchRoutes", "routes", "data", "results", "items", "myRoutes", "records", "me"] {
                if let v = dict[key], let found = findRoutesArray(v) { return found }
            }
            for (_, v) in dict {
                if let found = findRoutesArray(v) { return found }
            }
        }
        if let arr = obj as? [Any] {
            for v in arr {
                if let found = findRoutesArray(v) { return found }
            }
        }
        return nil
    }

    static func route(from d: [String: Any]) -> MyRoute? {
        guard let id = idString(d) else { return nil }
        let name = (d["title"] as? String) ?? (d["name"] as? String) ?? "Route \(id)"
        let distance = doubleValue(d, ["length", "distance"]).flatMap(Classification.formatDistance)
        let elevation = doubleValue(d, ["elevation_gain", "elevationGain", "elev_gain", "totalElevationGain"])
            .flatMap(Classification.formatMeters)
        return MyRoute(
            id: id, name: name,
            distanceText: distance, elevationText: elevation,
            thumbnailURL: thumbnailURL(d)
        )
    }

    static func idString(_ d: [String: Any]) -> String? {
        if let s = d["id_str"] as? String, !s.isEmpty { return s }
        if let n = d["id"] as? NSNumber { return n.stringValue }
        if let s = d["id"] as? String, !s.isEmpty { return s }
        if let n = d["route_id"] as? NSNumber { return n.stringValue }
        if let s = d["routeId"] as? String, !s.isEmpty { return s }
        return nil
    }

    static func doubleValue(_ d: [String: Any], _ keys: [String]) -> Double? {
        for k in keys {
            if let n = d[k] as? NSNumber { return n.doubleValue }
            if let s = d[k] as? String, let v = Double(s) { return v }
        }
        return nil
    }

    static func boolValue(_ obj: Any, keys: [String]) -> Bool? {
        if let d = obj as? [String: Any] {
            for k in keys {
                if let b = d[k] as? Bool { return b }
                if let n = d[k] as? NSNumber { return n.boolValue }
            }
            for (_, v) in d {
                if let found = boolValue(v, keys: keys) { return found }
            }
        }
        return nil
    }

    static func thumbnailURL(_ d: [String: Any]) -> URL? {
        // themedMapImages: [{lightUrl, darkUrl}]
        if let imgs = d["themedMapImages"] as? [[String: Any]], let first = imgs.first {
            for sk in ["lightUrl", "url", "darkUrl", "retina_url"] {
                if let s = first[sk] as? String, let u = URL(string: s) { return u }
            }
        }
        // 직접 키
        for k in ["imgUrl", "image_url", "imageUrl", "thumbnail", "mapImageUrl", "map_image_url"] {
            if let s = d[k] as? String, let u = URL(string: s) { return u }
        }
        // 중첩 맵 URL 객체
        for k in ["map_urls", "mapUrls", "mapImages", "map"] {
            if let m = d[k] as? [String: Any] {
                for sk in ["retina_url", "retinaUrl", "url", "2x", "1x", "src"] {
                    if let s = m[sk] as? String, let u = URL(string: s) { return u }
                }
            }
            if let a = d[k] as? [[String: Any]], let first = a.first {
                for sk in ["url", "src", "retina_url"] {
                    if let s = first[sk] as? String, let u = URL(string: s) { return u }
                }
            }
        }
        return nil
    }
}
