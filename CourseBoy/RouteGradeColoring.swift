import AppKit
import CourseBoyKit

// 지도의 경로를 경사도 색으로 칠하는 데 쓰는 것들. 모바일 앱의 GradeBand,
// MapElevationProfile의 순간 경사도, CourseRoutePolyline.gradeRuns와 같은 규칙이다.

/// 순간 경사도 구간.
enum GradeBand: CaseIterable, Hashable {
    case descent
    case flat
    case gentle
    case moderate
    case steep
    case extreme

    init(grade: Double) {
        switch grade {
        case ..<(-2): self = .descent
        case ..<2: self = .flat
        case ..<4: self = .gentle
        case ..<7: self = .moderate
        case ..<10: self = .steep
        default: self = .extreme
        }
    }

    var color: NSColor {
        switch self {
        case .descent: return NSColor(red: 0.30, green: 0.56, blue: 0.95, alpha: 1)
        case .flat: return NSColor(red: 0.36, green: 0.76, blue: 0.40, alpha: 1)
        case .gentle: return NSColor(red: 0.96, green: 0.82, blue: 0.20, alpha: 1)
        case .moderate: return NSColor(red: 0.98, green: 0.58, blue: 0.16, alpha: 1)
        case .steep: return NSColor(red: 0.90, green: 0.25, blue: 0.20, alpha: 1)
        case .extreme: return NSColor(red: 0.56, green: 0.16, blue: 0.40, alpha: 1)
        }
    }

    /// 경사 순서. 비슷한 경사 구간을 찾을 때 쓴다.
    var order: Int {
        Self.allCases.firstIndex(of: self) ?? 0
    }
}

/// 같은 경사도 색으로 칠할 연속 구간. 인덱스는 트랙 포인트 기준이다.
struct RouteGradeRun: Equatable {
    var startIndex: Int
    var endIndex: Int
    var band: GradeBand
}

enum RouteGradeColoring {
    /// 순간 경사도는 앞뒤 이만큼(km)의 고도 차로 낸다.
    static let gradeHalfWindowKm = 0.1
    /// 이보다 짧은 색 구간은 이웃 구간에 합친다. GPS 고도 노이즈로 색이 잘게 바뀌는 것을 막는다.
    static let minimumRunKm = 0.1

    /// 순간 경사도로 구간을 나눈 뒤 `minimumRunKm`보다 짧은 구간을 이웃에 합친다.
    static func runs(for trackPoints: [TrackPoint]) -> [RouteGradeRun] {
        guard trackPoints.count >= 2 else { return [] }
        let samples = gradeSamples(trackPoints)

        // 포인트 index-1 → index 구간은 끝 포인트의 경사도로 칠한다. 고도가 없는 포인트는 앞 값을 쓴다.
        var runs: [RouteGradeRun] = []
        var cursor = 0
        var grade = samples.first?.grade ?? 0
        for index in 1..<trackPoints.count {
            while cursor < samples.count, samples[cursor].trackIndex <= index {
                grade = samples[cursor].grade
                cursor += 1
            }
            let band = GradeBand(grade: grade)
            if let last = runs.last, last.band == band {
                runs[runs.count - 1].endIndex = index
            } else {
                runs.append(RouteGradeRun(startIndex: index - 1, endIndex: index, band: band))
            }
        }

        func length(_ run: RouteGradeRun) -> Double {
            trackPoints[run.endIndex].cumKm - trackPoints[run.startIndex].cumKm
        }

        // 가장 짧은 구간부터 경사도가 더 비슷한(같으면 더 긴) 이웃에 흡수시킨다.
        while runs.count > 1,
              let shortest = runs.indices.min(by: { length(runs[$0]) < length(runs[$1]) }),
              length(runs[shortest]) < minimumRunKm {
            let run = runs[shortest]
            let target: Int
            if shortest == 0 {
                target = 1
            } else if shortest == runs.count - 1 {
                target = shortest - 1
            } else {
                let previous = runs[shortest - 1]
                let next = runs[shortest + 1]
                let previousGap = abs(previous.band.order - run.band.order)
                let nextGap = abs(next.band.order - run.band.order)
                if previousGap != nextGap {
                    target = previousGap < nextGap ? shortest - 1 : shortest + 1
                } else {
                    target = length(previous) >= length(next) ? shortest - 1 : shortest + 1
                }
            }
            runs[target].startIndex = min(runs[target].startIndex, run.startIndex)
            runs[target].endIndex = max(runs[target].endIndex, run.endIndex)
            runs.remove(at: shortest)

            // 흡수 후 같은 색이 된 양옆 구간을 하나로 잇는다.
            let merged = target < shortest ? target : target - 1
            if merged + 1 < runs.count, runs[merged + 1].band == runs[merged].band {
                runs[merged].endIndex = runs[merged + 1].endIndex
                runs.remove(at: merged + 1)
            }
            if merged > 0, runs[merged - 1].band == runs[merged].band {
                runs[merged - 1].endIndex = runs[merged].endIndex
                runs.remove(at: merged)
            }
        }
        return runs
    }

    private struct Sample {
        var trackIndex: Int
        var km: Double
        var ele: Double
        var grade: Double
    }

    /// 고도가 있는 포인트마다 앞뒤 `gradeHalfWindowKm` 구간의 경사도.
    private static func gradeSamples(_ trackPoints: [TrackPoint]) -> [Sample] {
        var raw: [Sample] = []
        raw.reserveCapacity(trackPoints.count)
        for (index, point) in trackPoints.enumerated() {
            guard let ele = point.ele else { continue }
            raw.append(Sample(trackIndex: index, km: point.cumKm, ele: ele, grade: 0))
        }
        // 두 포인터로 ±gradeHalfWindowKm 구간의 양 끝을 찾는다.
        var lower = 0
        var upper = 0
        for index in raw.indices {
            let km = raw[index].km
            while lower < index, raw[lower].km < km - gradeHalfWindowKm {
                lower += 1
            }
            upper = max(upper, index)
            while upper + 1 < raw.count, raw[upper + 1].km <= km + gradeHalfWindowKm {
                upper += 1
            }
            let a = raw[max(0, min(lower, index - 1))]
            let b = raw[min(raw.count - 1, max(upper, index + 1))]
            let meters = (b.km - a.km) * 1000
            raw[index].grade = meters > 1 ? (b.ele - a.ele) / meters * 100 : 0
        }
        return raw
    }
}
