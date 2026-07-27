import Foundation

/// 트랙포인트 + 정렬된 segment 목록으로 CoursePoint 엔트리를 만든다.
/// Python add_cuesheet_to_tcx.py 의 main() 엔트리 수집 루프와 동일.
public enum Cuesheet {

    public struct Result: Sendable {
        public var entries: [CoursePointEntry]
        public var logLines: [String]
    }

    /// - Parameters:
    ///   - trackPoints: TCX 트랙포인트
    ///   - segments: order 순으로 정렬된 segment 목록
    ///   - minCategory: 포함할 최소 카테고리 ("4"|"3"|"2"|"1"|"HC"). nil 이면 전체.
    ///   - includedSegmentIDs: nil이면 전체, 값이 있으면 해당 ID만 큐시트에 포함한다.
    public static func makeEntries(
        trackPoints pts: [TrackPoint],
        segments: [SegmentInfo],
        minCategory: String? = nil,
        includedSegmentIDs: Set<String>? = nil
    ) -> Result {
        let minRank = minCategory.map { Classification.categoryRank($0) } ?? 0
        var entries: [CoursePointEntry] = []
        var logs: [String] = []
        let matches = RouteSegmentMatcher.match(trackPoints: pts, segments: segments)
        let orderedSegments = segments.enumerated().sorted { lhs, rhs in
            let lhsOrder = lhs.element.order ?? Int.max
            let rhsOrder = rhs.element.order ?? Int.max
            return lhsOrder == rhsOrder ? lhs.offset < rhs.offset : lhsOrder < rhsOrder
        }.map(\.element)

        for info in orderedSegments {
            let name = info.name.isEmpty ? "Segment" : info.name

            if let includedSegmentIDs, !includedSegmentIDs.contains(info.segmentID) {
                continue
            }

            // 카테고리 필터
            if minRank > 0, Classification.categoryRank(info.climbCategory) < minRank {
                continue
            }

            let startPt = info.startPoint
            let endPt = info.endPoint
            if startPt == nil && endPt == nil {
                logs.append("⚠️ segment \(info.segmentID): 좌표 없음 - skip")
                continue
            }

            // 기본 _cued.tcx 용 Notes 요약
            var notesBits: [String] = []
            if let d = info.distanceText, !d.isEmpty { notesBits.append("Dist \(d)") }
            if let e = info.elevDifference, !e.isEmpty { notesBits.append("Elev \(e)") }
            if let g = info.avgGrade, !g.isEmpty, let fg = Classification.formatGrade(g) {
                notesBits.append("Grade \(fg)")
            }
            if let cat = info.climbCategory, !cat.isEmpty { notesBits.append("Cat \(cat)") }
            notesBits.append("id:\(info.segmentID)")
            let baseNotes = notesBits.joined(separator: " | ")

            let order = info.order.map(String.init) ?? "?"
            let gclass = Classification.gradeClass(info.avgGrade)

            // 시작 지점
            let startIdx = matches[info.segmentID]?.startIndex
            if let i = startIdx {
                let stype = gclass == .up ? Classification.startPointType(info.climbCategory) : "Straight"
                entries.append(CoursePointEntry(
                    idx: i, time: pts[i].time, lat: pts[i].lat, lon: pts[i].lon, ele: pts[i].ele,
                    pointType: stype, baseName: name, baseNotes: baseNotes, segName: name,
                    isStart: true, dist: info.distanceText, grade: info.avgGrade, gradeClass: gclass
                ))
                logs.append("  + \(pad(order, 3)). \(truncate(name + " 시작", 30)) [\(stype)] @ tp#\(i)")
            }

            // 종료 지점 (시작점 이후만 탐색)
            if endPt != nil, let i = matches[info.segmentID]?.endIndex {
                let etype = gclass == .down ? "Valley" : "Summit"
                entries.append(CoursePointEntry(
                    idx: i, time: pts[i].time, lat: pts[i].lat, lon: pts[i].lon, ele: pts[i].ele,
                    pointType: etype, baseName: "\(name) 종료", baseNotes: baseNotes, segName: name,
                    isStart: false, dist: info.distanceText, grade: info.avgGrade, gradeClass: gclass
                ))
                logs.append("  + \(pad(order, 3)). \(truncate(name + " 종료", 30)) [\(etype)] @ tp#\(i)")
            }
        }

        return Result(entries: entries, logLines: logs)
    }

    private static func pad(_ s: String, _ width: Int) -> String {
        s.count >= width ? s : String(repeating: " ", count: width - s.count) + s
    }

    private static func truncate(_ s: String, _ max: Int) -> String {
        String(s.prefix(max))
    }
}
