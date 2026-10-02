import Foundation

/// 큐시트 구간의 종류. 오르막은 HC가 가장 어렵다.
/// 큐시트 생성기는 오르막 세그먼트 시작에 등급(등급이 없으면 Sprint)을, 내리막 세그먼트 끝에 Valley를 넣는다.
public enum ClimbCategory: Int, CaseIterable, Comparable, Sendable {
    /// 내리막 세그먼트. 시작 큐는 Straight라 PointType으로는 알 수 없고 Valley 큐와 짝지어 찾는다.
    case downhill = -1
    case sprint = 0
    case fourth
    case third
    case second
    case first
    case hors

    /// "4th Category"(CourseBoy)와 "Fourth Category"(Garmin TCX) 표기를 모두 인식한다.
    public init?(pointType: String) {
        switch canonicalCuePointType(pointType) {
        case "4th Category": self = .fourth
        case "3rd Category": self = .third
        case "2nd Category": self = .second
        case "1st Category": self = .first
        case "Hors Category": self = .hors
        case "Sprint": self = .sprint
        default: return nil
        }
    }

    public var shortLabel: String {
        switch self {
        case .downhill: return "↘"
        case .sprint: return "S"
        case .fourth: return "4"
        case .third: return "3"
        case .second: return "2"
        case .first: return "1"
        case .hors: return "HC"
        }
    }

    public var label: String {
        switch self {
        case .downhill: return "다운힐"
        case .sprint: return "스프린트"
        case .hors: return "HC급"
        default: return "\(shortLabel)등급"
        }
    }

    public static func < (lhs: ClimbCategory, rhs: ClimbCategory) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 큐시트로 인식한 구간.
/// 오르막(등급·스프린트)은 시작 큐부터 고도 그래프상 오르막이 끝나는 지점까지,
/// 다운힐은 시작 큐부터 짝지은 Valley 큐까지다.
public struct CourseClimbSection: Identifiable, Equatable, Sendable {
    public var id: UUID { startCue.id }

    public var startCue: CourseCuePoint
    public var category: ClimbCategory
    /// 구간 끝 큐. 오르막은 끝 근처에서 찾은 정상(Summit) 큐, 다운힐은 Valley 큐다.
    public var summitCue: CourseCuePoint?

    public var startIndex: Int
    public var endIndex: Int
    public var startKm: Double
    public var endKm: Double
    public var startElevation: Double?
    public var endElevation: Double?
    public var ascent: Double
    public var descent: Double
    /// 퍼센트 단위. 약 200m 구간 평균 중 가장 가파른 값. 다운힐은 가장 가파른 내리막(음수)이다.
    public var maxGrade: Double?

    public var isDownhill: Bool { category == .downhill }

    public var name: String { startCue.displayName }

    public var lengthKm: Double { max(0, endKm - startKm) }

    public var elevationGain: Double? {
        guard let startElevation, let endElevation else { return nil }
        return endElevation - startElevation
    }

    /// 퍼센트 단위. 시작과 끝의 고도차 / 거리.
    public var averageGrade: Double? {
        guard let elevationGain, lengthKm > 0.001 else { return nil }
        return elevationGain / (lengthKm * 1_000) * 100
    }

    public func contains(distanceKm: Double) -> Bool {
        distanceKm >= startKm - 0.000_1 && distanceKm <= endKm + 0.000_1
    }
}

public enum CourseClimbDetector {
    /// 고도 노이즈를 줄이려고 앞뒤로 평균내는 거리.
    static let smoothingHalfWindowKm = 0.05
    /// 정상에서 이만큼 내려가면 오르막이 끝난 것으로 본다. 상승량의 10%를 쓰되 이 범위로 제한한다.
    static let minimumDropMeters = 15.0
    static let maximumDropMeters = 40.0
    /// 정상 이후 이 거리 동안 더 높은 곳이 없으면 오르막이 끝난 것으로 본다.
    static let plateauKm = 2.0
    static let maxGradeWindowKm = 0.2
    /// 거리 창 경계에 정확히 걸친 포인트가 부동소수점 오차로 빠지지 않게 한다.
    private static let epsilonKm = 1e-9

    public static func sections(in course: LoadedCourse) -> [CourseClimbSection] {
        let points = course.trackPoints
        let elevations = smoothedElevations(points)
        guard points.count > 1, elevations.contains(where: { $0 != nil }) else { return [] }

        let cues = course.sortedCuePoints
        let summits = cues.filter { canonicalCuePointType($0.pointType) == "Summit" }

        let climbs = cues.compactMap { cue -> CourseClimbSection? in
            guard let category = ClimbCategory(pointType: cue.pointType),
                  let startIndex = cueTrackIndex(cue, in: points) else {
                return nil
            }
            let startKm = points[startIndex].cumKm
            // 큐시트가 끝 지점을 알려 주면 그 정상 큐에서 끝내고, 아니면 고도 그래프로 끝을 찾는다.
            let summit: CourseCuePoint?
            let endIndex: Int
            if let paired = pairedSummit(for: cue, startKm: startKm, in: summits),
               let pairedIndex = cueTrackIndex(paired, in: points),
               pairedIndex > startIndex {
                summit = paired
                endIndex = pairedIndex
            } else {
                endIndex = climbEndIndex(from: startIndex, points: points, elevations: elevations)
                summit = matchSummit(for: cue, startKm: startKm, endKm: points[endIndex].cumKm, in: summits)
            }
            let range = startIndex...endIndex
            let (ascent, descent) = elevationChange(points, in: range)
            let endKm = points[endIndex].cumKm

            let section = CourseClimbSection(
                startCue: cue,
                category: category,
                summitCue: summit,
                startIndex: startIndex,
                endIndex: endIndex,
                startKm: startKm,
                endKm: endKm,
                startElevation: points[startIndex].ele,
                endElevation: points[endIndex].ele,
                ascent: ascent,
                descent: descent,
                maxGrade: steepestGrade(points, elevations: elevations, in: range, descending: false)
            )
            return section
        }
        let downhills = downhillSections(cues: cues, points: points, elevations: elevations)
        return (climbs + downhills).sorted { $0.startKm < $1.startKm }
    }

    /// Valley 큐마다 앞쪽의 시작 큐를 찾아 다운힐 구간을 만든다. 시작 큐를 못 찾으면 구간으로 보지 않는다.
    static func downhillSections(
        cues: [CourseCuePoint],
        points: [TrackPoint],
        elevations: [Double?]
    ) -> [CourseClimbSection] {
        cues.indices.compactMap { valleyOffset -> CourseClimbSection? in
            let valley = cues[valleyOffset]
            guard canonicalCuePointType(valley.pointType) == "Valley",
                  let start = matchDownhillStart(for: valleyOffset, in: cues),
                  let startIndex = cueTrackIndex(start, in: points),
                  let endIndex = cueTrackIndex(valley, in: points),
                  endIndex > startIndex else {
                return nil
            }
            let range = startIndex...endIndex
            let (ascent, descent) = elevationChange(points, in: range)
            return CourseClimbSection(
                startCue: start,
                category: .downhill,
                summitCue: valley,
                startIndex: startIndex,
                endIndex: endIndex,
                startKm: points[startIndex].cumKm,
                endKm: points[endIndex].cumKm,
                startElevation: points[startIndex].ele,
                endElevation: points[endIndex].ele,
                ascent: ascent,
                descent: descent,
                maxGrade: steepestGrade(points, elevations: elevations, in: range, descending: true)
            )
        }
    }

    /// Valley 큐("<이름> 종료")와 같은 이름의 앞쪽 큐를 먼저 찾는다.
    /// RWGPS용 큐시트처럼 이름이 이어지지 않으면 "↘"로 시작하는 바로 앞 큐를 쓴다.
    static func matchDownhillStart(for valleyOffset: Int, in cues: [CourseCuePoint]) -> CourseCuePoint? {
        let valleyName = cues[valleyOffset].name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = valleyName.hasSuffix(" 종료") ? String(valleyName.dropLast(" 종료".count)) : valleyName
        let before = cues[..<valleyOffset].reversed()
        if !baseName.isEmpty,
           let named = before.first(where: { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == baseName }) {
            return named
        }
        for cue in before {
            // 다른 다운힐이 끝난 뒤의 큐만 본다.
            if canonicalCuePointType(cue.pointType) == "Valley" { return nil }
            if cue.name.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("↘") { return cue }
        }
        return nil
    }

    /// 시작점부터 앞으로 가며 가장 높은 지점을 따라가다가, 충분히 내려가거나 평지가 이어지면 멈춘다.
    static func climbEndIndex(from startIndex: Int, points: [TrackPoint], elevations: [Double?]) -> Int {
        let startElevation = elevations[startIndex] ?? elevations[startIndex...].compactMap { $0 }.first ?? 0
        var peakIndex = startIndex
        var peakElevation = startElevation
        guard startIndex + 1 < points.count else { return startIndex }

        for index in (startIndex + 1)..<points.count {
            guard let elevation = elevations[index] else { continue }
            if elevation > peakElevation {
                peakElevation = elevation
                peakIndex = index
                continue
            }
            let gain = peakElevation - startElevation
            let dropTolerance = min(max(gain * 0.1, minimumDropMeters), maximumDropMeters)
            if peakElevation - elevation >= dropTolerance { break }
            if points[index].cumKm - points[peakIndex].cumKm >= plateauKm { break }
        }
        return refinedPeakIndex(near: peakIndex, notBefore: startIndex, points: points)
    }

    /// 평활화로 살짝 밀린 정상을 원래 고도 기준 가장 높은 포인트로 맞춘다.
    private static func refinedPeakIndex(near index: Int, notBefore lowerLimit: Int, points: [TrackPoint]) -> Int {
        let km = points[index].cumKm
        var best = index
        var bestElevation = points[index].ele ?? -.infinity
        var cursor = index - 1
        while cursor >= lowerLimit, km - points[cursor].cumKm <= smoothingHalfWindowKm {
            if let ele = points[cursor].ele, ele > bestElevation { best = cursor; bestElevation = ele }
            cursor -= 1
        }
        cursor = index + 1
        while cursor < points.count, points[cursor].cumKm - km <= smoothingHalfWindowKm {
            if let ele = points[cursor].ele, ele > bestElevation { best = cursor; bestElevation = ele }
            cursor += 1
        }
        return best
    }

    /// 큐시트가 짝지어 둔 정상 큐. "<시작 큐 이름> 종료"를 먼저 찾고,
    /// RWGPS용 큐시트처럼 시작 큐 이름이 "↗2.45km, 3.8%"면 그 길이만큼 간 곳의 정상 큐를 쓴다.
    static func pairedSummit(
        for cue: CourseCuePoint,
        startKm: Double,
        in summits: [CourseCuePoint]
    ) -> CourseCuePoint? {
        let after = summits.filter { $0.distanceKm > startKm }
        let baseName = cue.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !baseName.isEmpty,
           let named = after.first(where: {
               $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == "\(baseName) 종료"
           }) {
            return named
        }
        guard let lengthKm = arrowLengthKm(in: baseName) else { return nil }
        let expectedKm = startKm + lengthKm
        let tolerance = min(max(lengthKm * 0.2, 0.3), 1.0)
        return after
            .filter { abs($0.distanceKm - expectedKm) <= tolerance }
            .min { abs($0.distanceKm - expectedKm) < abs($1.distanceKm - expectedKm) }
    }

    /// "↗509m, 2.7%"나 "↗2.45km, 3.8%"에서 길이(km)를 읽는다.
    static func arrowLengthKm(in name: String) -> Double? {
        guard name.hasPrefix("↗") else { return nil }
        let body = name.dropFirst().prefix { $0 != "," }.trimmingCharacters(in: .whitespaces)
        if body.hasSuffix("km"), let km = Double(body.dropLast(2)) { return km }
        if body.hasSuffix("m"), let meters = Double(body.dropLast()) { return meters / 1_000 }
        return nil
    }

    /// 오르막 끝 근처의 정상 큐. "<시작 큐 이름> 종료"처럼 이름이 이어지는 큐를 먼저 찾는다.
    static func matchSummit(
        for cue: CourseCuePoint,
        startKm: Double,
        endKm: Double,
        in summits: [CourseCuePoint]
    ) -> CourseCuePoint? {
        let tolerance = min(max((endKm - startKm) * 0.2, 0.3), 1.0)
        let nearby = summits.filter {
            $0.distanceKm >= startKm && abs($0.distanceKm - endKm) <= tolerance
        }
        let baseName = cue.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !baseName.isEmpty,
           let named = nearby.first(where: {
               $0.name.trimmingCharacters(in: .whitespacesAndNewlines) == "\(baseName) 종료"
           }) {
            return named
        }
        return nearby.min { abs($0.distanceKm - endKm) < abs($1.distanceKm - endKm) }
    }

    static func smoothedElevations(_ points: [TrackPoint]) -> [Double?] {
        var result = [Double?](repeating: nil, count: points.count)
        var lower = 0
        var upper = 0
        var sum = 0.0
        var count = 0
        for index in points.indices {
            let km = points[index].cumKm
            while upper < points.count, points[upper].cumKm <= km + smoothingHalfWindowKm + epsilonKm {
                if let ele = points[upper].ele { sum += ele; count += 1 }
                upper += 1
            }
            while lower < index, points[lower].cumKm < km - smoothingHalfWindowKm - epsilonKm {
                if let ele = points[lower].ele { sum -= ele; count -= 1 }
                lower += 1
            }
            if points[index].ele != nil, count > 0 {
                result[index] = sum / Double(count)
            }
        }
        return result
    }

    private static func elevationChange(_ points: [TrackPoint], in range: ClosedRange<Int>) -> (Double, Double) {
        var up = 0.0
        var down = 0.0
        var previous: Double?
        for index in range {
            guard let ele = points[index].ele else { continue }
            if let previous {
                let delta = ele - previous
                if delta > 0 { up += delta } else { down -= delta }
            }
            previous = ele
        }
        return (up, down)
    }

    /// 약 200m 창 평균 경사 중 가장 가파른 값. descending이면 가장 가파른 내리막(가장 작은 값)을 고른다.
    private static func steepestGrade(
        _ points: [TrackPoint],
        elevations: [Double?],
        in range: ClosedRange<Int>,
        descending: Bool
    ) -> Double? {
        var best: Double?
        var ahead = range.lowerBound
        for index in range {
            guard let start = elevations[index] else { continue }
            ahead = max(ahead, index)
            while ahead < range.upperBound,
                  points[ahead].cumKm - points[index].cumKm < maxGradeWindowKm - epsilonKm {
                ahead += 1
            }
            let meters = (points[ahead].cumKm - points[index].cumKm) * 1_000
            // 구간 끝에 가까워 창이 절반도 안 되면 짧은 구간의 튀는 값을 피하려고 건너뛴다.
            guard meters >= maxGradeWindowKm * 500, let end = elevations[ahead] else { continue }
            let grade = (end - start) / meters * 100
            best = descending ? min(best ?? grade, grade) : max(best ?? grade, grade)
        }
        return best
    }
}
