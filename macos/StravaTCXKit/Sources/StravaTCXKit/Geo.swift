import Foundation

/// __NEXT_DATA__ / 캐시 파일의 최상위 래퍼: {"props": {"pageProps": {...}}}
public struct NextData: Decodable, Sendable {
    public struct Props: Decodable, Sendable {
        public var pageProps: PageProps?
    }
    public var props: Props?

    /// JSON Data 에서 pageProps 추출.
    public static func pageProps(from data: Data) throws -> PageProps? {
        try JSONDecoder().decode(NextData.self, from: data).props?.pageProps
    }
}

/// 지리 계산 (Python haversine_km / nearest_*_index 대응).
public enum Geo {
    static let earthRadiusKm = 6371.0088

    public static func haversineKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let p1 = lat1 * .pi / 180
        let p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180
        let dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return earthRadiusKm * 2 * atan2(sqrt(a), sqrt(1 - a))
    }

    /// pts[start...] 중 (lat,lon) 에 가장 가까운 인덱스.
    public static func nearestIndex(
        _ pts: [TrackPoint], lat: Double?, lon: Double?, startIdx: Int = 0
    ) -> Int? {
        guard let lat, let lon, startIdx < pts.count else { return nil }
        var bestI: Int?
        var bestD = Double.infinity
        for i in startIdx..<pts.count {
            let d = haversineKm(pts[i].lat, pts[i].lon, lat, lon)
            if d < bestD { bestD = d; bestI = i }
        }
        return bestI
    }
}

/// TCX 트랙포인트 (누적거리 포함).
public struct TrackPoint: Sendable {
    public var lat: Double
    public var lon: Double
    public var ele: Double?
    public var time: String?
    public var cumKm: Double

    public init(lat: Double, lon: Double, ele: Double?, time: String?, cumKm: Double) {
        self.lat = lat
        self.lon = lon
        self.ele = ele
        self.time = time
        self.cumKm = cumKm
    }
}
