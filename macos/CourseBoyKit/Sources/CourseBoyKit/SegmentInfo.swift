import Foundation

/// Strava segment 페이지 __NEXT_DATA__ 의 props.pageProps 구조 (필요한 부분만).
public struct PageProps: Decodable, Sendable {
    public struct Metadata: Decodable, Sendable {
        public var name: String?
        public var climbCategory: String?
        public var activityType: String?
        public var displayLocation: String?

        private enum CodingKeys: String, CodingKey {
            case name, segmentName, title
            case climbCategory, activityType, displayLocation
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name)
                ?? c.decodeIfPresent(String.self, forKey: .segmentName)
                ?? c.decodeIfPresent(String.self, forKey: .title)
            // climbCategory 는 보통 "Category2" 문자열이지만 숫자로 올 수도 있어 유연 처리
            climbCategory = try c.decodeFlexibleString(forKey: .climbCategory)
            activityType = try c.decodeIfPresent(String.self, forKey: .activityType)
            displayLocation = try c.decodeIfPresent(String.self, forKey: .displayLocation)
        }
    }

    public struct Measurements: Decodable, Sendable {
        public var distance: Double?
        public var avgGrade: Double?
        public var elevLow: Double?
        public var elevHigh: Double?
        public var elevGain: Double?
        public var elevDifference: Double?

        private enum CodingKeys: String, CodingKey {
            case distance
            case avgGrade, averageGrade, average_grade
            case elevLow, elevationLow, lowestElevation, elevation_low
            case elevHigh, elevationHigh, highestElevation, elevation_high
            case elevGain, elevationGain, elevation_gain, totalElevationGain
            case elevDifference, elevationDifference, elev_difference
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func pick(_ keys: [CodingKeys]) throws -> Double? {
                for k in keys where c.contains(k) {
                    if let v = try c.decodeIfPresent(Double.self, forKey: k) { return v }
                }
                return nil
            }
            distance = try pick([.distance])
            avgGrade = try pick([.avgGrade, .averageGrade, .average_grade])
            elevLow = try pick([.elevLow, .elevationLow, .lowestElevation, .elevation_low])
            elevHigh = try pick([.elevHigh, .elevationHigh, .highestElevation, .elevation_high])
            elevGain = try pick([.elevGain, .elevationGain, .elevation_gain, .totalElevationGain])
            elevDifference = try pick([.elevDifference, .elevationDifference, .elev_difference])
        }
    }

    public struct Streams: Decodable, Sendable {
        public var location: [[Double]]?
        public var distance: [Double]?
        public var elevation: [Double]?
    }

    public struct MapImage: Decodable, Sendable {
        public var url: String?
        public var width: Int?
        public var height: Int?
    }

    public var metadata: Metadata?
    public var measurements: Measurements?
    public var streams: Streams?
    public var mapImages: [MapImage]?
}

/// 처리된 segment 정보 (Python result dict 대응). UI/파이프라인에서 사용.
public struct SegmentInfo: Sendable, Identifiable, Codable, Hashable {
    public var segmentID: String
    public var name: String
    public var startPoint: [Double]?   // [lat, lng]
    public var endPoint: [Double]?
    public var distanceText: String?
    public var distanceMeters: Double?
    public var elevationGain: String?
    public var avgGrade: String?
    public var lowestElev: String?
    public var highestElev: String?
    public var elevDifference: String?
    public var climbCategory: String?  // 정규화된 "2"/"HC"/nil
    public var imageURL: String?       // segment 지도 미리보기 이미지 (mapImages 첫 항목)

    // streams 에서 채워지는 경로 데이터
    public var coordinates: [[Double]]?  // [[lat, lng], ...]
    public var distances: [Double]?      // 각 포인트의 누적 거리 (m)
    public var elevations: [Double]?     // 각 포인트의 고도 (m)

    // extract 단계에서 채워지는 enrich 값
    public var order: Int?
    public var startKm: Double?
    public var endKm: Double?
    public var distanceKm: Double?

    public var id: String { segmentID }

    public init(segmentID: String, name: String) {
        self.segmentID = segmentID
        self.name = name
    }

    /// pageProps → SegmentInfo (Python _result_from_pageprops 와 동일 규칙).
    public static func from(pageProps: PageProps, segmentID: String) -> SegmentInfo {
        var r = SegmentInfo(segmentID: segmentID, name: "Unknown Segment Name")

        let rawName = pageProps.metadata?.name ?? "Unknown Segment Name"
        r.name = rawName.replacingOccurrences(of: "☆", with: "").trimmingCharacters(in: .whitespaces)

        if let loc = pageProps.streams?.location, loc.count >= 2 {
            if let first = loc.first, first.count == 2 { r.startPoint = [first[0], first[1]] }
            if let last = loc.last, last.count == 2    { r.endPoint   = [last[0],  last[1]]  }
            r.coordinates = loc
        }
        r.distances  = pageProps.streams?.distance
        r.elevations = pageProps.streams?.elevation

        let m = pageProps.measurements
        r.distanceMeters = m?.distance
        r.distanceText = Classification.formatDistance(m?.distance)
        r.elevationGain = Classification.formatMeters(m?.elevGain)
        r.avgGrade = Classification.formatPercent(m?.avgGrade)
        r.lowestElev = Classification.formatMeters(m?.elevLow)
        r.highestElev = Classification.formatMeters(m?.elevHigh)

        var diff = m?.elevDifference
        if diff == nil, let low = m?.elevLow, let high = m?.elevHigh {
            diff = high - low
        }
        r.elevDifference = Classification.formatMeters(diff)
        r.climbCategory = Classification.normalizeClimbCategory(pageProps.metadata?.climbCategory)
        r.imageURL = pageProps.mapImages?.first(where: { $0.url != nil })?.url
        return r
    }
}

// MARK: - 유연한 String 디코딩 (String 또는 숫자)

private extension KeyedDecodingContainer {
    func decodeFlexibleString(forKey key: Key) throws -> String? {
        if let s = try? decodeIfPresent(String.self, forKey: key) { return s }
        if let i = try? decodeIfPresent(Int.self, forKey: key) { return String(i) }
        if let d = try? decodeIfPresent(Double.self, forKey: key) { return Classification.trimNumber(d) }
        return nil
    }
}
