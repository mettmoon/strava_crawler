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

    /// 누적거리와 가장 가까운 트랙포인트 인덱스. `cumKm` 오름차순을 이용한다.
    public static func nearestIndex(_ pts: [TrackPoint], distanceKm: Double) -> Int? {
        guard !pts.isEmpty, distanceKm.isFinite else { return nil }
        if distanceKm <= pts[0].cumKm { return 0 }
        if distanceKm >= pts[pts.count - 1].cumKm { return pts.count - 1 }

        var low = 0
        var high = pts.count - 1
        while low < high {
            let mid = (low + high) / 2
            if pts[mid].cumKm < distanceKm {
                low = mid + 1
            } else {
                high = mid
            }
        }

        let upper = low
        let lower = upper - 1
        return abs(pts[lower].cumKm - distanceKm) <= abs(pts[upper].cumKm - distanceKm)
            ? lower
            : upper
    }

    /// 좌표에 가까운 후보들 중 누적거리까지 가장 잘 맞는 트랙포인트 인덱스.
    ///
    /// 왕복/교차 경로처럼 같은 좌표를 여러 번 통과할 때 좌표만으로는 올바른
    /// 통과 지점을 고를 수 없다. 좌표상 최단 지점에서 50m 이내인 후보로 범위를
    /// 제한한 뒤, 저장된 코스 누적거리와 가장 가까운 지점을 선택한다.
    public static func nearestIndex(
        _ pts: [TrackPoint],
        lat: Double?,
        lon: Double?,
        distanceKm: Double?
    ) -> Int? {
        guard !pts.isEmpty else { return nil }
        guard let lat, let lon else {
            return distanceKm.flatMap { nearestIndex(pts, distanceKm: $0) }
        }
        guard let distanceKm, distanceKm.isFinite else {
            return nearestIndex(pts, lat: lat, lon: lon)
        }

        var spatialDistances: [Double] = []
        spatialDistances.reserveCapacity(pts.count)
        var nearestSpatialDistance = Double.infinity
        for point in pts {
            let distance = haversineKm(point.lat, point.lon, lat, lon)
            spatialDistances.append(distance)
            nearestSpatialDistance = min(nearestSpatialDistance, distance)
        }

        let candidateLimitKm = nearestSpatialDistance + 0.05
        var bestIndex: Int?
        var bestCourseDistanceError = Double.infinity
        var bestSpatialDistance = Double.infinity
        for index in pts.indices where spatialDistances[index] <= candidateLimitKm {
            let courseDistanceError = abs(pts[index].cumKm - distanceKm)
            let spatialDistance = spatialDistances[index]
            if courseDistanceError < bestCourseDistanceError
                || (courseDistanceError == bestCourseDistanceError && spatialDistance < bestSpatialDistance) {
                bestIndex = index
                bestCourseDistanceError = courseDistanceError
                bestSpatialDistance = spatialDistance
            }
        }
        return bestIndex
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
