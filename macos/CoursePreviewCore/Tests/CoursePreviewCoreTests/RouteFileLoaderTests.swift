import XCTest
@testable import CoursePreviewCore

final class RouteFileLoaderTests: XCTestCase {
    func testLoadsTCXTitleTrackAndCue() throws {
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Courses><Course>
            <Name>한강 코스</Name>
            <Track>
              <Trackpoint><Time>2026-01-01T00:00:00Z</Time><Position><LatitudeDegrees>37.5</LatitudeDegrees><LongitudeDegrees>127.0</LongitudeDegrees></Position><AltitudeMeters>10</AltitudeMeters></Trackpoint>
              <Trackpoint><Time>2026-01-01T00:01:00Z</Time><Position><LatitudeDegrees>37.51</LatitudeDegrees><LongitudeDegrees>127.01</LongitudeDegrees></Position><AltitudeMeters>20</AltitudeMeters></Trackpoint>
            </Track>
            <CoursePoint><Name>우회전</Name><Time>2026-01-01T00:01:00Z</Time><Position><LatitudeDegrees>37.51</LatitudeDegrees><LongitudeDegrees>127.01</LongitudeDegrees></Position><PointType>Right</PointType><Notes>교차로</Notes></CoursePoint>
          </Course></Courses>
        </TrainingCenterDatabase>
        """.utf8)

        let course = try RouteFileLoader.load(data: data, filename: "route.tcx")

        XCTAssertEqual(course.title, "한강 코스")
        XCTAssertEqual(course.fileKind, .tcx)
        XCTAssertEqual(course.trackPoints.count, 2)
        XCTAssertEqual(course.cuePoints.first?.pointType, "Right")
        XCTAssertGreaterThan(course.totalDistanceKm, 0)
    }

    func testLoadsGPXAndMapsWaypointType() throws {
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="CourseBoy">
          <trk><name>남산</name><trkseg>
            <trkpt lat="37.55" lon="126.99"><ele>20</ele></trkpt>
            <trkpt lat="37.56" lon="127.00"><ele>80</ele></trkpt>
          </trkseg></trk>
          <wpt lat="37.56" lon="127.00"><name>Water Stop</name></wpt>
        </gpx>
        """.utf8)

        let course = try RouteFileLoader.load(data: data, filename: "route.GPX")

        XCTAssertEqual(course.title, "남산")
        XCTAssertEqual(course.fileKind, .gpx)
        XCTAssertEqual(course.cuePoints.first?.pointType, "Water")
        XCTAssertEqual(course.elevationStats.ascent, 60)
    }

    func testLoadsCSBVersionThree() throws {
        let data = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <CoursePlan version="3">
          <Metadata><Title>새 코스</Title></Metadata>
          <Sections><Section id="00000000-0000-0000-0000-000000000001">
            <Legs><Leg kind="routed">
              <TrackPoint lat="37.1" lon="127.1" ele="12" cumKm="0"/>
              <TrackPoint lat="37.2" lon="127.2" ele="25" cumKm="14.2"/>
            </Leg></Legs>
            <CuePoints><CuePoint lat="37.2" lon="127.2" pointType="Summit" distanceMeters="14200"><Name>정상</Name><Notes>휴식</Notes></CuePoint></CuePoints>
          </Section></Sections>
        </CoursePlan>
        """.utf8)

        let course = try RouteFileLoader.load(data: data, filename: "course.csb")

        XCTAssertEqual(course.title, "새 코스")
        XCTAssertEqual(course.fileKind, .csb)
        XCTAssertEqual(course.trackPoints.count, 2)
        XCTAssertEqual(course.cuePoints.first?.distanceMeters, 14_200)
    }

    func testLoadsLegacyCSBVersions() throws {
        let versionOne = Data("""
        <CoursePlan version="1">
          <Metadata><Title>v1 코스</Title></Metadata>
          <TrackSegments><TrackSegment>
            <TrackPoint lat="37.0" lon="127.0" cumKm="0"/>
            <TrackPoint lat="37.01" lon="127.01" cumKm="1"/>
          </TrackSegment></TrackSegments>
        </CoursePlan>
        """.utf8)
        let versionTwo = Data("""
        <CoursePlan version="2">
          <Metadata><Title>v2 코스</Title></Metadata>
          <Sections><Section><Legs><Leg>
            <TrackPoint lat="36.0" lon="128.0" cumKm="0"/>
            <TrackPoint lat="36.01" lon="128.01" cumKm="1"/>
          </Leg></Legs></Section></Sections>
        </CoursePlan>
        """.utf8)

        XCTAssertEqual(
            try RouteFileLoader.load(data: versionOne, filename: "v1.csb").title,
            "v1 코스"
        )
        XCTAssertEqual(
            try RouteFileLoader.load(data: versionTwo, filename: "v2.csb").title,
            "v2 코스"
        )
    }

    func testRejectsUnsupportedCSBVersion() {
        let data = Data("""
        <CoursePlan version="99">
          <TrackPoint lat="37.0" lon="127.0"/>
        </CoursePlan>
        """.utf8)

        XCTAssertThrowsError(
            try RouteFileLoader.load(data: data, filename: "future.csb")
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("지원하지 않는 CSB"))
        }
    }

    func testUsesFilenameWhenTitleIsMissing() throws {
        let data = Data("""
        <gpx><trk><trkseg><trkpt lat="37.0" lon="127.0"/></trkseg></trk></gpx>
        """.utf8)

        let course = try RouteFileLoader.load(data: data, filename: "morning-ride.gpx")
        XCTAssertEqual(course.title, "morning-ride")
    }

    func testRejectsUnsupportedExtension() {
        XCTAssertThrowsError(
            try RouteFileLoader.load(data: Data(), filename: "route.fit")
        ) { error in
            XCTAssertEqual(error as? RouteFileLoadError, .unsupportedFileType("fit"))
        }
    }

    func testRejectsFileWithoutTrackpoints() {
        XCTAssertThrowsError(
            try RouteFileLoader.load(data: Data("<gpx/>".utf8), filename: "empty.gpx")
        ) { error in
            XCTAssertEqual(error as? RouteFileLoadError, .noTrackpoints)
        }
    }
}
