import XCTest
@testable import CoursePreviewCore

final class CourseClimbSectionsTests: XCTestCase {
    /// 0~2km 평지(100m) → 2~5km 오르막(100→400m) → 5~8km 내리막 → 8~10km 평지.
    private func makeTrack() -> [TrackPoint] {
        stride(from: 0.0, through: 10.0, by: 0.05).map { km in
            let ele: Double
            switch km {
            case ..<2: ele = 100
            case ..<5: ele = 100 + (km - 2) * 100
            case ..<8: ele = 400 - (km - 5) * 90
            default: ele = 130
            }
            return TrackPoint(lat: 37 + km / 100, lon: 127, ele: ele, time: nil, cumKm: km)
        }
    }

    private func cue(_ name: String, _ type: String, km: Double) -> CourseCuePoint {
        CourseCuePoint(lat: 37 + km / 100, lon: 127, name: name, pointType: type, notes: "", distanceMeters: km * 1_000)
    }

    private func course(cues: [CourseCuePoint]) -> LoadedCourse {
        LoadedCourse(
            title: "테스트",
            sourceURL: URL(fileURLWithPath: "/tmp/test.tcx"),
            fileKind: .tcx,
            routePoints: [],
            trackPoints: makeTrack(),
            cuePoints: cues
        )
    }

    func testRecognizesBothCategorySpellings() {
        XCTAssertEqual(ClimbCategory(pointType: "4th Category"), .fourth)
        XCTAssertEqual(ClimbCategory(pointType: "Fourth Category"), .fourth)
        XCTAssertEqual(ClimbCategory(pointType: "Hors Category"), .hors)
        XCTAssertNil(ClimbCategory(pointType: "Summit"))
        XCTAssertEqual(ClimbCategory(pointType: "Sprint"), .sprint)
        XCTAssertEqual(cuePointLabel(for: "Second Category"), "2등급 오르막")
    }

    func testDetectsClimbEndAtPeak() throws {
        let sections = CourseClimbDetector.sections(in: course(cues: [
            cue("업힐", "3rd Category", km: 2),
            cue("우회전", "Right", km: 3),
        ]))

        let section = try XCTUnwrap(sections.first)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(section.category, .third)
        XCTAssertEqual(section.startKm, 2, accuracy: 0.001)
        XCTAssertEqual(section.endKm, 5, accuracy: 0.06)
        XCTAssertEqual(try XCTUnwrap(section.elevationGain), 300, accuracy: 6)
        XCTAssertEqual(try XCTUnwrap(section.averageGrade), 10, accuracy: 0.3)
        XCTAssertEqual(try XCTUnwrap(section.maxGrade), 10, accuracy: 0.5)
        XCTAssertNil(section.summitCue)
    }

    func testPrefersSummitNamedAfterClimb() throws {
        let sections = CourseClimbDetector.sections(in: course(cues: [
            cue("A", "Fourth Category", km: 2),
            cue("B", "4th Category", km: 2.05),
            cue("A 종료", "Summit", km: 4.9),
            cue("B 종료", "Summit", km: 5.0),
            cue("먼 정상", "Summit", km: 9),
        ]))

        XCTAssertEqual(sections.map(\.name), ["A", "B"])
        XCTAssertEqual(sections[0].summitCue?.name, "A 종료")
        XCTAssertEqual(sections[1].summitCue?.name, "B 종료")
    }

    func testMatchesNearestSummitWithinTolerance() throws {
        let sections = CourseClimbDetector.sections(in: course(cues: [
            cue("업힐", "HC", km: 2),
            cue("고개", "Summit", km: 5.2),
        ]))
        XCTAssertEqual(sections.first?.category, .hors)
        XCTAssertEqual(sections.first?.summitCue?.name, "고개")

        let farSummit = CourseClimbDetector.sections(in: course(cues: [
            cue("업힐", "2nd Category", km: 2),
            cue("먼 정상", "Summit", km: 7),
        ]))
        XCTAssertNil(farSummit.first?.summitCue)
    }

    func testIncludesSprintOnlyWhenUphill() {
        let sections = CourseClimbDetector.sections(in: course(cues: [
            cue("평지 스프린트", "Sprint", km: 8.2),
            cue("오르막 스프린트", "Sprint", km: 3),
            cue("내리막 스프린트", "Sprint", km: 6),
        ]))

        XCTAssertEqual(sections.map(\.name), ["오르막 스프린트"])
        XCTAssertEqual(sections.first?.category, .sprint)
        XCTAssertEqual(sections.first?.category.label, "스프린트")
    }
}
