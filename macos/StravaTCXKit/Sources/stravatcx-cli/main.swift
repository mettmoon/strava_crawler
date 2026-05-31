import Foundation
import StravaTCXKit

// 간단한 오프라인 cuesheet 실행기 (Python add_cuesheet_to_tcx.py 교차검증용).
//   stravatcx --tcx route.tcx --segments route_segments.json [--min-category 4] [--out out.tcx]

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
    return a[i + 1]
}

guard let tcxPath = arg("--tcx"), let segPath = arg("--segments") else {
    FileHandle.standardError.write(Data("usage: stravatcx --tcx <tcx> --segments <json> [--min-category 4] [--out <tcx>]\n".utf8))
    exit(2)
}
let minCategory = arg("--min-category")
let outPath = arg("--out") ?? (tcxPath as NSString).deletingPathExtension + "_cued.tcx"

do {
    let tcxData = try Data(contentsOf: URL(fileURLWithPath: tcxPath))
    let segData = try Data(contentsOf: URL(fileURLWithPath: segPath))

    let course = try TCXCourse(data: tcxData)
    let segments = try RouteSegments.load(data: segData)
    print("📍 trackpoint \(course.trackPoints.count) 개")
    print("📄 \(segments.count) segments")

    let result = Cuesheet.makeEntries(
        trackPoints: course.trackPoints, segments: segments, minCategory: minCategory
    )
    result.logLines.forEach { print($0) }

    let cued = try course.build(entries: result.entries, forRWGPS: false)
    try cued.data.write(to: URL(fileURLWithPath: outPath))
    print("✅ \(cued.count) 개 CoursePoint 추가 → \(outPath)")

    let base = (outPath as NSString).deletingPathExtension
    let ext = (outPath as NSString).pathExtension
    let rwgpsPath = "\(base)_for_rwgps.\(ext)"
    let rwgps = try course.build(entries: result.entries, forRWGPS: true)
    try rwgps.data.write(to: URL(fileURLWithPath: rwgpsPath))
    print("✅ \(rwgps.count) 개 CoursePoint 추가 (RWGPS) → \(rwgpsPath)")
} catch {
    FileHandle.standardError.write(Data("❌ \(error.localizedDescription)\n".utf8))
    exit(1)
}
