import Foundation

/// Python route_<id>_segments.json (enriched dict) 로딩/저장.
public enum RouteSegments {

    private struct Entry: Decodable {
        var name: String?
        var start_point: [Double]?
        var end_point: [Double]?
        var distance: String?
        var elevation_gain: String?
        var avg_grade: String?
        var lowest_elev: String?
        var highest_elev: String?
        var elev_difference: String?
        var climb_category: String?
        var order: Int?
        var start_km: Double?
        var end_km: Double?
        var distance_km: Double?
        var error: String?

        private enum CodingKeys: String, CodingKey {
            case name, start_point, end_point, distance, elevation_gain, avg_grade
            case lowest_elev, highest_elev, elev_difference, climb_category
            case order, start_km, end_km, distance_km, error
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            start_point = try c.decodeIfPresent([Double].self, forKey: .start_point)
            end_point = try c.decodeIfPresent([Double].self, forKey: .end_point)
            distance = try c.decodeIfPresent(String.self, forKey: .distance)
            elevation_gain = try c.decodeIfPresent(String.self, forKey: .elevation_gain)
            avg_grade = try c.decodeIfPresent(String.self, forKey: .avg_grade)
            lowest_elev = try c.decodeIfPresent(String.self, forKey: .lowest_elev)
            highest_elev = try c.decodeIfPresent(String.self, forKey: .highest_elev)
            elev_difference = try c.decodeIfPresent(String.self, forKey: .elev_difference)
            climb_category = try c.decodeFlexibleStringPublic(forKey: .climb_category)
            order = try c.decodeIfPresent(Int.self, forKey: .order)
            start_km = try c.decodeIfPresent(Double.self, forKey: .start_km)
            end_km = try c.decodeIfPresent(Double.self, forKey: .end_km)
            distance_km = try c.decodeIfPresent(Double.self, forKey: .distance_km)
            error = try c.decodeIfPresent(String.self, forKey: .error)
        }
    }

    /// route_segments.json Data → order 순 [SegmentInfo].
    public static func load(data: Data) throws -> [SegmentInfo] {
        let dict = try JSONDecoder().decode([String: Entry].self, from: data)
        var result: [SegmentInfo] = []
        for (sid, e) in dict {
            if e.error != nil { continue }
            var info = SegmentInfo(segmentID: sid, name: (e.name ?? "Segment"))
            info.startPoint = e.start_point
            info.endPoint = e.end_point
            info.distanceText = e.distance
            info.elevationGain = e.elevation_gain
            info.avgGrade = e.avg_grade
            info.lowestElev = e.lowest_elev
            info.highestElev = e.highest_elev
            info.elevDifference = e.elev_difference
            info.climbCategory = Classification.normalizeClimbCategory(e.climb_category)
            info.order = e.order
            info.startKm = e.start_km
            info.endKm = e.end_km
            info.distanceKm = e.distance_km
            result.append(info)
        }
        result.sort { ($0.order ?? Int.max) < ($1.order ?? Int.max) }
        return result
    }
}

extension KeyedDecodingContainer {
    /// String 또는 숫자를 String? 으로 유연 디코딩.
    func decodeFlexibleStringPublic(forKey key: Key) throws -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Classification.trimNumber(d) }
        return nil
    }
}
