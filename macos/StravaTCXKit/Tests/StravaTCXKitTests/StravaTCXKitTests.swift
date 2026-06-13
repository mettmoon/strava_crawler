import XCTest
@testable import StravaTCXKit

final class ClassificationTests: XCTestCase {

    func testNormalizeClimbCategory() {
        XCTAssertEqual(Classification.normalizeClimbCategory("2"), "2")
        XCTAssertEqual(Classification.normalizeClimbCategory("Category2"), "2")
        XCTAssertEqual(Classification.normalizeClimbCategory("CategoryHC"), "HC")
        XCTAssertEqual(Classification.normalizeClimbCategory("HC"), "HC")
        XCTAssertNil(Classification.normalizeClimbCategory("0"))
        XCTAssertNil(Classification.normalizeClimbCategory("NC"))
        XCTAssertNil(Classification.normalizeClimbCategory(nil))
    }

    func testStartPointTypeAndRank() {
        XCTAssertEqual(Classification.startPointType("Category2"), "2nd Category")
        XCTAssertEqual(Classification.startPointType("4"), "4th Category")
        XCTAssertEqual(Classification.startPointType(nil), "Sprint")
        XCTAssertEqual(Classification.categoryRank("Category2"), 3)
        XCTAssertEqual(Classification.categoryRank("HC"), 5)
        XCTAssertEqual(Classification.categoryRank(nil), 0)
    }

    func testGradeClassBoundaries() {
        XCTAssertEqual(Classification.gradeClass("7.0%"), .up)
        XCTAssertEqual(Classification.gradeClass("1.5%"), .flat)
        XCTAssertEqual(Classification.gradeClass("1.6%"), .up)
        XCTAssertEqual(Classification.gradeClass("-1.5%"), .flat)
        XCTAssertEqual(Classification.gradeClass("-1.6%"), .down)
        XCTAssertEqual(Classification.gradeClass("-4.2%"), .down)
        XCTAssertEqual(Classification.gradeClass(nil), .flat)
    }

    func testFormatGrade() {
        XCTAssertEqual(Classification.formatGrade("7.86396%"), "7.9%")
        XCTAssertEqual(Classification.formatGrade("7%"), "7.0%")
        XCTAssertEqual(Classification.formatGrade("0.49724%"), "0.5%")
    }

    func testResolveSegmentName() {
        XCTAssertEqual(Classification.resolveSegmentName("떙기러가즈아~ by 팀바둑이"), "떙기러가즈아")
        XCTAssertEqual(Classification.resolveSegmentName("🜲 아우라지-암내교 21km TT #령재치"), "아우라지-암내교 21km TT")
        XCTAssertEqual(Classification.resolveSegmentName("나전고개 서측 #령재치"), "나전고개 서측")
        XCTAssertEqual(Classification.resolveSegmentName("만항재 북-남"), "만항재 북-남")
        XCTAssertEqual(Classification.resolveSegmentName("Baby Steps Climb"), "Baby Steps Climb")
    }

    func testFormatters() {
        XCTAssertEqual(Classification.formatDistance(7888), "7.89 km")
        XCTAssertEqual(Classification.formatDistance(505), "505 m")
        XCTAssertEqual(Classification.formatMeters(529.2), "529 m")
        XCTAssertEqual(Classification.formatPercent(6.708920001983643), "6.70892%")
    }
}

final class SegmentInfoTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
        return try Data(contentsOf: try XCTUnwrap(url))
    }

    func testFromPageProps() throws {
        let data = try fixture("segment_9646037.json")
        let pp = try XCTUnwrap(NextData.pageProps(from: data))
        let info = SegmentInfo.from(pageProps: pp, segmentID: "9646037")

        XCTAssertEqual(info.name, "만항재 북-남")
        XCTAssertEqual(info.climbCategory, "2")          // "Category2" → "2"
        XCTAssertEqual(info.distanceText, "7.89 km")
        XCTAssertEqual(info.elevationGain, "529 m")
        XCTAssertEqual(info.lowestElev, "958 m")
        XCTAssertEqual(info.highestElev, "1487 m")
        XCTAssertEqual(info.elevDifference, "529 m")     // 1487 - 958
        XCTAssertNotNil(info.startPoint)
        XCTAssertEqual(info.startPoint?.count, 2)
    }
}

final class CuesheetIntegrationTests: XCTestCase {

    private func fixtureURL(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    }

    /// 실제 라우트 TCX + segments json 으로 cuesheet 생성 → Python 결과(32 CoursePoint)와 대조.
    func testCuesheetMatchesPython() throws {
        let tcxData = try Data(contentsOf: try fixtureURL("route.tcx"))
        let segData = try Data(contentsOf: try fixtureURL("route_segments.json"))

        let course = try TCXCourse(data: tcxData)
        XCTAssertEqual(course.trackPoints.count, 4648)

        let segments = try RouteSegments.load(data: segData)
        XCTAssertEqual(segments.count, 30)

        // 전체(필터 없음): 좌표 있는 segment 마다 시작+종료 2개
        let all = Cuesheet.makeEntries(trackPoints: course.trackPoints, segments: segments)
        XCTAssertGreaterThan(all.entries.count, 0)
        XCTAssertEqual(all.entries.count % 2, 0)

        // --min-category 4 → Python 과 동일하게 32개
        let cat4 = Cuesheet.makeEntries(
            trackPoints: course.trackPoints, segments: segments, minCategory: "4"
        )
        XCTAssertEqual(cat4.entries.count, 32)

        // PointType 분포 검증 (Python: Straight/Valley/Summit/카테고리)
        let starts = cat4.entries.filter { $0.isStart }
        let ends = cat4.entries.filter { !$0.isStart }
        XCTAssertEqual(starts.count, 16)
        XCTAssertEqual(ends.count, 16)
        // 내리막 시작은 Straight, 내리막 종료는 Valley
        for e in cat4.entries where e.gradeClass == .down {
            XCTAssertEqual(e.pointType, e.isStart ? "Straight" : "Valley")
        }
        // 오르막 종료는 Summit
        for e in ends where e.gradeClass == .up {
            XCTAssertEqual(e.pointType, "Summit")
        }
    }

    /// 생성된 TCX 가 유효한 XML 이고 CoursePoint 가 올바르게 삽입되는지 round-trip 검증.
    func testBuildProducesValidTCX() throws {
        let tcxData = try Data(contentsOf: try fixtureURL("route.tcx"))
        let segData = try Data(contentsOf: try fixtureURL("route_segments.json"))
        let course = try TCXCourse(data: tcxData)
        let segments = try RouteSegments.load(data: segData)
        let result = Cuesheet.makeEntries(
            trackPoints: course.trackPoints, segments: segments, minCategory: "4"
        )

        // RWGPS 출력: Name == Notes, 시작 prefix(↗/→/↘), 종료 prefix(🏁)
        let rwgps = try course.build(entries: result.entries, forRWGPS: true)
        XCTAssertEqual(rwgps.count, 32)

        let doc = try XMLDocument(data: rwgps.data)
        let cps = TCXCourse.allElements(in: try XCTUnwrap(doc.rootElement()), localName: "CoursePoint")
        XCTAssertEqual(cps.count, 32)

        func childText(_ e: XMLElement, _ name: String) -> String? {
            e.elements(forName: name).first?.stringValue
        }
        var prefixes = Set<Character>()
        for cp in cps {
            let name = childText(cp, "Name") ?? ""
            let notes = childText(cp, "Notes") ?? ""
            XCTAssertEqual(name, String(notes.prefix(32)), "RWGPS Name 은 Notes(32자) 와 동일해야 함")
            if let first = notes.first { prefixes.insert(first) }
            // CoursePoint 가 TCX 기본 네임스페이스에 있는지 (xmlns="" 오염 방지)
            XCTAssertEqual(cp.uri, tcxNamespace)
        }
        XCTAssertTrue(prefixes.contains("🏁"))
        XCTAssertTrue(prefixes.contains("↗") || prefixes.contains("→") || prefixes.contains("↘"))
    }

    func testBuildCourseDataRoundTripsCoursePoints() throws {
        let trackPoints = [
            TrackPoint(lat: 37.0, lon: 127.0, ele: 12, time: "2026-06-13T00:00:00Z", cumKm: 0),
            TrackPoint(lat: 37.1, lon: 127.1, ele: 42, time: "2026-06-13T00:10:00Z", cumKm: 14.2),
        ]
        let cues = [
            TCXCourse.CuePointSpec(
                idx: 1,
                time: trackPoints[1].time,
                lat: trackPoints[1].lat,
                lon: trackPoints[1].lon,
                ele: trackPoints[1].ele,
                name: "Summit",
                pointType: "Summit",
                notes: "manual"
            )
        ]

        let built = try TCXCourse.buildCourseData(title: "Manual Course", trackPoints: trackPoints, cuePoints: cues)
        XCTAssertEqual(built.count, 1)

        let parsed = try TCXCourse(data: built.data)
        XCTAssertEqual(parsed.courseName, "Manual Course")
        XCTAssertEqual(parsed.trackPoints.count, 2)
        XCTAssertEqual(parsed.coursePoints.count, 1)
        XCTAssertEqual(parsed.coursePoints[0].name, "Summit")
        XCTAssertEqual(parsed.coursePoints[0].pointType, "Summit")
        XCTAssertEqual(parsed.coursePoints[0].notes, "manual")
    }
}

final class MyRoutesTests: XCTestCase {

    func testRequestBody() throws {
        let data = MyRoutesParser.requestBody(after: "16", pageSize: 16)
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["after"] as? String, "16")
        XCTAssertEqual(obj["pageSize"] as? Int, 16)
        let args = try XCTUnwrap(obj["searchArgs"] as? [String: Any])
        XCTAssertEqual(args["createdBy"] as? String, "Any")
        XCTAssertTrue((args["routeTypes"] as? [String])?.contains("GravelRide") ?? false)
    }

    func testExtractCSRF() {
        let html = #"<head><meta name="csrf-token" content="abc123=="></head>"#
        XCTAssertEqual(MyRoutesParser.extractCSRF(html: html), "abc123==")
    }

    func testParseRealSchema() throws {
        // 실제 응답: me.searchRoutes.nodes + pageInfo
        let json = """
        {"me":{"id":"21608570","measurementPreference":"Metric","searchRoutes":{"nodes":[
          {"title":"충주호 남부 123K","id":"3496036741620946856","isStarred":false,
           "elevationGain":1628.17,"length":123364.98,"estimatedTime":{"expectedTime":17191.18},
           "themedMapImages":[{"lightUrl":"https://cdn/a.png"}],"routeType":"Ride",
           "athlete":{"id":"21608570"},"isPrivate":true},
          {"title":"2026 FAR01: 정선","id":"3495269006478904270","isStarred":false,
           "elevationGain":3616.79,"length":198492.01,"themedMapImages":[{"lightUrl":"https://cdn/b.png"}],
           "routeType":"Ride","athlete":{"id":"21608570"},"isPrivate":true}
        ],"pageInfo":{"endCursor":"15","startCursor":"0","hasNextPage":true,"hasPreviousPage":false}}}}
        """
        let page = MyRoutesParser.parse(Data(json.utf8), pageSize: 16)
        XCTAssertEqual(page.routes.count, 2)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextAfter, "16")   // endCursor 15 + 1
        XCTAssertEqual(page.routes[0].id, "3496036741620946856")
        XCTAssertEqual(page.routes[0].name, "충주호 남부 123K")
        XCTAssertEqual(page.routes[0].distanceText, "123.36 km")
        XCTAssertEqual(page.routes[0].elevationText, "1628 m")
        XCTAssertEqual(page.routes[0].thumbnailURL?.absoluteString, "https://cdn/a.png")
        XCTAssertEqual(page.routes[1].id, "3495269006478904270")
    }

    func testParseHasMoreHeuristic() {
        // hasMore 키가 없으면 (받은 개수 >= pageSize) 로 추정
        let json = #"{"data":{"results":[{"id":1,"name":"a"},{"id":2,"name":"b"}]}}"#
        let page = MyRoutesParser.parse(Data(json.utf8), pageSize: 2)
        XCTAssertEqual(page.routes.count, 2)
        XCTAssertTrue(page.hasMore)
        let page2 = MyRoutesParser.parse(Data(json.utf8), pageSize: 16)
        XCTAssertFalse(page2.hasMore)
    }
}

final class StravaClientParsingTests: XCTestCase {

    func testExtractSegmentIDsOrderAndDedup() {
        let html = """
        <div data-segment-id="111"></div>
        <a href="/segments/222">x</a>
        <a href="/segments/111">dup</a>
        <script>{"segments":[{"id":333},{"segment_id":444}]}</script>
        """
        XCTAssertEqual(StravaClient.extractSegmentIDs(html: html), ["111", "222", "333", "444"])
    }

    func testExtractNextDataJSON() {
        let html = #"<html><script id="__NEXT_DATA__" type="application/json">{"a":1}</script></html>"#
        XCTAssertEqual(StravaClient.extractNextDataJSON(html: html), #"{"a":1}"#)
    }
}
