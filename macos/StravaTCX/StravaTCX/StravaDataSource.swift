import Foundation
import StravaTCXKit

/// 앱이 데이터를 얻는 추상 인터페이스. Stub(샘플) / Live(실 Strava) 두 구현.
/// 세그먼트는 ID 목록 → 개별 조회로 나눠 AppModel 이 진행률을 보고할 수 있게 한다.
protocol StravaDataSource: Sendable {
    func downloadTCX(routeID: String, cookie: String) async throws -> Data
    func fetchSegmentIDs(routeID: String, cookie: String) async throws -> [String]
    func fetchSegment(id: String, cookie: String) async throws -> SegmentInfo
}

// MARK: - Live (실 Strava 스크래핑)

struct LiveDataSource: StravaDataSource {
    private func client(_ cookie: String) -> StravaClient {
        let trimmed = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
        let cookies = trimmed.isEmpty ? [:] : ["_strava4_session": trimmed]
        return StravaClient(cookies: cookies)
    }

    func downloadTCX(routeID: String, cookie: String) async throws -> Data {
        try await client(cookie).downloadRouteTCX(routeID: routeID)
    }

    func fetchSegmentIDs(routeID: String, cookie: String) async throws -> [String] {
        try await client(cookie).fetchSegmentIDs(routeID: routeID)
    }

    func fetchSegment(id: String, cookie: String) async throws -> SegmentInfo {
        try await client(cookie).fetchSegment(segmentID: id)
    }
}

// MARK: - Stub (합성 샘플, 오프라인 데모)

struct StubDataSource: StravaDataSource {
    func downloadTCX(routeID: String, cookie: String) async throws -> Data {
        try await Task.sleep(nanoseconds: 400_000_000)
        return SampleData.tcxData
    }

    func fetchSegmentIDs(routeID: String, cookie: String) async throws -> [String] {
        try await Task.sleep(nanoseconds: 300_000_000)
        return SampleData.segments.map(\.segmentID)
    }

    func fetchSegment(id: String, cookie: String) async throws -> SegmentInfo {
        try await Task.sleep(nanoseconds: 250_000_000)
        return SampleData.segments.first { $0.segmentID == id }
            ?? SegmentInfo(segmentID: id, name: "Unknown")
    }
}

/// 합성 트랙/세그먼트 (stub 전용).
enum SampleData {
    static let points: [(lat: Double, lon: Double, ele: Double)] = {
        var arr: [(Double, Double, Double)] = []
        var lat = 37.4500, lon = 128.6600, ele = 300.0
        for i in 0..<60 {
            arr.append((lat, lon, ele))
            lat += 0.0015
            lon += 0.0011
            ele += (i % 9 < 5 ? 9 : -7)
        }
        return arr
    }()

    static var tcxData: Data {
        var tps = ""
        for (i, p) in points.enumerated() {
            tps += """
            <Trackpoint>\
            <Time>2024-01-01T00:\(String(format: "%02d", i)):00Z</Time>\
            <Position><LatitudeDegrees>\(p.lat)</LatitudeDegrees>\
            <LongitudeDegrees>\(p.lon)</LongitudeDegrees></Position>\
            <AltitudeMeters>\(String(format: "%.1f", p.ele))</AltitudeMeters>\
            </Trackpoint>
            """
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
        <Courses><Course><Name>샘플 라우트</Name><Track>\(tps)</Track></Course></Courses>
        </TrainingCenterDatabase>
        """
        return Data(xml.utf8)
    }

    static var segments: [SegmentInfo] {
        [
            make("9001", "만항재 북-남", cat: "2", grade: "7.0%", s: 4, e: 12, dist: "3.30 km", order: 1),
            make("9002", "장열고개 평지구간", cat: nil, grade: "0.5%", s: 16, e: 22, dist: "2.10 km", order: 2),
            make("9003", "건천고개 다운 by 팀바둑이", cat: nil, grade: "-6.0%", s: 26, e: 34, dist: "2.40 km", order: 3),
            make("9004", "🜲 아우라지 TT #령재치", cat: "4", grade: "4.0%", s: 40, e: 47, dist: "5.05 km", order: 4),
        ]
    }

    private static func make(
        _ id: String, _ name: String, cat: String?, grade: String,
        s: Int, e: Int, dist: String, order: Int
    ) -> SegmentInfo {
        var info = SegmentInfo(segmentID: id, name: name)
        info.startPoint = [points[s].lat, points[s].lon]
        info.endPoint = [points[e].lat, points[e].lon]
        info.climbCategory = Classification.normalizeClimbCategory(cat)
        info.avgGrade = grade
        info.distanceText = dist
        info.order = order
        return info
    }
}
