import Foundation
import CourseBoyKit

/// 코스 편집 세션의 로컬 작업 복사본.
/// 문서 모델을 직접 건드리지 않고, 저장 시에만 CourseRecord에 커밋한다.
/// 모든 변경은 snapshot 기반 undo/redo를 지원한다.
@Observable
final class CourseEditorDraft {
    var sections: [CourseSection]
    var selectedSectionID: UUID
    var title: String

    var selectedSectionIndex: Int {
        sections.firstIndex { $0.id == selectedSectionID } ?? 0
    }

    var routePoints: [CourseRoutePoint] { sections[selectedSectionIndex].routePoints }
    var trackSegments: [[TrackPointCodable]] { sections[selectedSectionIndex].legs.map(\.trackPoints) }
    var cuePoints: [CourseCuePoint] { sections[selectedSectionIndex].cuePoints }

    let undoManager = UndoManager()

    /// UndoManager의 canUndo/canRedo는 KVO/Notification으로만 갱신되므로
    /// SwiftUI 버튼 disabled 상태를 위해 수동으로 관리하는 트리거.
    var undoCount: Int = 0  // undo/redo 호출 시 토글해 View를 재렌더링

    private let initialSnapshot: Snapshot
    private var notificationObservers: [NSObjectProtocol] = []

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    init(from course: CourseRecord) {
        var initialSections = course.sections.isEmpty ? [CourseSection()] : course.sections
        for index in initialSections.indices {
            initialSections[index].cuePoints.sort { $0.distanceMeters < $1.distanceMeters }
        }
        let initialSectionID = initialSections[0].id
        sections = initialSections
        selectedSectionID = initialSectionID
        title = course.title
        initialSnapshot = Snapshot(
            title: course.title,
            sections: initialSections,
            selectedSectionID: initialSectionID
        )

        // UndoManager 변경 시 undoCount를 갱신해 SwiftUI View가 재렌더링되도록 한다.
        let center = NotificationCenter.default
        let names: [NSNotification.Name] = [.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
                                             .NSUndoManagerDidOpenUndoGroup, .NSUndoManagerDidCloseUndoGroup]
        notificationObservers = names.map { name in
            center.addObserver(forName: name, object: undoManager, queue: .main) { [weak self] _ in
                self?.undoCount &+= 1
            }
        }
    }

    /// allTrackPoints 캐시. trackSegments 의 identity(개수+각 구간 길이+첫/끝 좌표)로 무효화.
    /// @ObservationIgnored 로 두어 캐시 갱신이 SwiftUI 재렌더링을 유발하지 않게 한다.
    @ObservationIgnored private var _allTrackPointsCache: [TrackPoint] = []
    @ObservationIgnored private var _allTrackPointsSignature: String = "invalid"

    /// 전체 트랙포인트 (모든 구간 이어붙임, 구간 이음새 중복 제거 후 cumKm 재계산).
    /// `CourseRecord.allTrackPoints`와 동일한 규칙.
    ///
    /// 매 SwiftUI body 평가마다 재계산되면 5k+ 포인트에서 심각한 낭비.
    /// trackSegments 시그니처가 바뀔 때만 재계산한다.
    var allTrackPoints: [TrackPoint] {
        let sig = selectedSectionID.uuidString + "#" + Self.trackSegmentsSignature(trackSegments)
        if sig == _allTrackPointsSignature {
            return _allTrackPointsCache
        }
        var raw: [TrackPointCodable] = []
        for (segIdx, seg) in trackSegments.enumerated() {
            let slice = segIdx == 0 ? seg : Array(seg.dropFirst())
            raw.append(contentsOf: slice)
        }
        var result: [TrackPoint] = []
        result.reserveCapacity(raw.count)
        var cumKm: Double = 0
        for (i, tp) in raw.enumerated() {
            if i > 0 {
                let prev = raw[i - 1]
                cumKm += Geo.haversineKm(prev.lat, prev.lon, tp.lat, tp.lon)
            }
            result.append(TrackPoint(lat: tp.lat, lon: tp.lon, ele: tp.ele, time: nil, cumKm: cumKm))
        }
        _allTrackPointsCache = result
        _allTrackPointsSignature = sig
        return result
    }

    /// trackSegments 의 구조적 시그니처. 전체 좌표 해시 대신 count/양끝 좌표로 근사.
    /// 편집 API 들이 항상 trackSegments 를 통째로 교체하므로 충돌 가능성이 낮다.
    private static func trackSegmentsSignature(_ segs: [[TrackPointCodable]]) -> String {
        if segs.isEmpty { return "empty" }
        var parts: [String] = []
        parts.reserveCapacity(segs.count)
        for seg in segs {
            guard let first = seg.first, let last = seg.last else {
                parts.append("0")
                continue
            }
            parts.append(String(
                format: "%d:%.6f,%.6f→%.6f,%.6f",
                seg.count, first.lat, first.lon, last.lat, last.lon
            ))
        }
        return parts.joined(separator: "|")
    }

    /// 현재 draft 상태를 문서 모델에 반영한다.
    func commit(to course: CourseRecord) {
        course.sections = sections
        course.title = normalizedTitle
    }

    var normalizedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasValidTitle: Bool {
        !normalizedTitle.isEmpty
    }

    var hasChanges: Bool {
        title != initialSnapshot.title || sections != initialSnapshot.sections
    }

    // MARK: - Snapshot undo

    private struct Snapshot: Equatable {
        let title: String
        let sections: [CourseSection]
        let selectedSectionID: UUID
    }

    private func takeSnapshot() -> Snapshot {
        Snapshot(title: title, sections: sections, selectedSectionID: selectedSectionID)
    }

    private func restore(_ s: Snapshot) {
        title = s.title
        sections = s.sections
        selectedSectionID = sections.contains { $0.id == s.selectedSectionID }
            ? s.selectedSectionID
            : sections[0].id
    }

    /// 변경 전 snapshot을 받아 undo/redo 쌍을 등록한다.
    private func registerUndo(before old: Snapshot, actionName: String) {
        undoManager.registerUndo(withTarget: self) { draft in
            let redo = draft.takeSnapshot()
            draft.restore(old)
            draft.undoManager.registerUndo(withTarget: draft) { d in
                let reundo = d.takeSnapshot()
                d.restore(redo)
                d.undoManager.registerUndo(withTarget: d) { dd in
                    dd.restore(reundo)
                }
                d.undoManager.setActionName(actionName)
            }
            draft.undoManager.setActionName(actionName)
        }
        undoManager.setActionName(actionName)
    }

    // MARK: - 제목 변경

    func updateTitle(_ newTitle: String) {
        guard newTitle != title else { return }
        let old = takeSnapshot()
        title = newTitle
        registerUndo(before: old, actionName: "코스 제목 변경")
    }

    // MARK: - RoutePoint 변경

    func appendRoutePoint(_ rp: CourseRoutePoint) {
        let old = takeSnapshot()
        sections[selectedSectionIndex].routePoints.append(rp)
        registerUndo(before: old, actionName: "RoutePoint 추가")
    }

    func appendLastSegment(_ seg: [TrackPointCodable]) {
        let old = takeSnapshot()
        sections[selectedSectionIndex].legs.append(CourseLeg(kind: .routed, trackPoints: seg))
        registerUndo(before: old, actionName: "경로 추가")
    }

    /// RoutePoint 추가 + 구간을 하나의 undo 작업으로 묶는다.
    func appendRoutePoint(_ rp: CourseRoutePoint, segment: [TrackPointCodable]) {
        let old = takeSnapshot()
        sections[selectedSectionIndex].routePoints.append(rp)
        sections[selectedSectionIndex].legs.append(CourseLeg(kind: .routed, trackPoints: segment))
        registerUndo(before: old, actionName: "RoutePoint 추가")
    }

    func removeRoutePoint(
        at idx: Int,
        joiningSegment: [TrackPointCodable]? = nil,
        joiningKind: CourseLeg.Kind = .routed
    ) {
        let old = takeSnapshot()
        let originalRoutePointCount = routePoints.count
        let wasMiddlePoint = idx > 0 && idx < originalRoutePointCount - 1
        sections[selectedSectionIndex].routePoints.remove(at: idx)
        if routePoints.count <= 1 {
            sections[selectedSectionIndex].legs = []
        } else if wasMiddlePoint {
            // 양쪽 leg를 제거하고 새 연결 leg 하나로 대체한다.
            sections[selectedSectionIndex].legs.remove(at: idx)
            sections[selectedSectionIndex].legs.remove(at: idx - 1)
            if let joiningSegment {
                sections[selectedSectionIndex].legs.insert(
                    CourseLeg(kind: joiningKind, trackPoints: joiningSegment),
                    at: idx - 1
                )
            }
        } else {
            let segIdx = max(0, idx - 1)
            if segIdx < sections[selectedSectionIndex].legs.count {
                sections[selectedSectionIndex].legs.remove(at: segIdx)
            }
        }
        registerUndo(before: old, actionName: "RoutePoint 삭제")
    }

    func moveRoutePoint(at idx: Int, to newRP: CourseRoutePoint, updatedSegments: [[TrackPointCodable]]) {
        let old = takeSnapshot()
        sections[selectedSectionIndex].routePoints[idx] = newRP
        replaceLegTrackPoints(updatedSegments)
        registerUndo(before: old, actionName: "RoutePoint 이동")
    }

    func replaceSegments(_ newSegments: [[TrackPointCodable]]) {
        let old = takeSnapshot()
        replaceLegTrackPoints(newSegments)
        registerUndo(before: old, actionName: "경로 재계산")
    }

    // MARK: - CuePoint 변경

    func appendCuePoint(_ cue: CourseCuePoint) {
        let old = takeSnapshot()
        sections[selectedSectionIndex].cuePoints.append(cue)
        sections[selectedSectionIndex].cuePoints.sort { $0.distanceMeters < $1.distanceMeters }
        registerUndo(before: old, actionName: "큐시트 추가")
    }

    func removeCuePoints(at offsets: IndexSet) {
        let old = takeSnapshot()
        sections[selectedSectionIndex].cuePoints.remove(atOffsets: offsets)
        registerUndo(before: old, actionName: "큐시트 삭제")
    }

    func updateCuePoint(_ cue: CourseCuePoint) {
        guard let idx = cuePoints.firstIndex(where: { $0.id == cue.id }) else { return }
        let old = takeSnapshot()
        sections[selectedSectionIndex].cuePoints[idx] = cue
        sections[selectedSectionIndex].cuePoints.sort { $0.distanceMeters < $1.distanceMeters }
        registerUndo(before: old, actionName: "큐시트 수정")
    }

    // MARK: - 섹션 변경

    func selectSection(_ id: UUID) {
        guard sections.contains(where: { $0.id == id }) else { return }
        selectedSectionID = id
    }

    func addSection() {
        let old = takeSnapshot()
        let newSection = CourseSection()
        let insertIndex = selectedSectionIndex + 1
        sections.insert(newSection, at: insertIndex)
        selectedSectionID = newSection.id
        registerUndo(before: old, actionName: "섹션 추가")
    }

    func deleteSelectedSection() {
        let old = takeSnapshot()
        let index = selectedSectionIndex
        if sections.count == 1 {
            let empty = CourseSection(id: sections[0].id)
            sections = [empty]
            selectedSectionID = empty.id
        } else {
            sections.remove(at: index)
            selectedSectionID = sections[min(index, sections.count - 1)].id
        }
        registerUndo(before: old, actionName: "섹션 삭제")
    }

    var canMergeSelectedWithNext: Bool { selectedSectionIndex + 1 < sections.count }

    var selectedSectionCourseStartKm: Double {
        sections.prefix(selectedSectionIndex).reduce(0) { $0 + $1.distanceKm }
    }

    var selectedSectionCourseRangeKm: ClosedRange<Double> {
        let start = selectedSectionCourseStartKm
        return start ... (start + sections[selectedSectionIndex].distanceKm)
    }

    func courseStartKm(forSectionAt index: Int) -> Double {
        guard index > 0 else { return 0 }
        return sections.prefix(index).reduce(0) { $0 + $1.distanceKm }
    }

    func sectionIndex(containingCourseDistanceKm distanceKm: Double) -> Int? {
        guard distanceKm >= 0, !sections.isEmpty else { return nil }
        var start = 0.0
        for index in sections.indices {
            let end = start + sections[index].distanceKm
            if distanceKm >= start,
               distanceKm < end || (index == sections.count - 1 && distanceKm <= end) {
                return index
            }
            start = end
        }
        return nil
    }

    func selectedSectionLocalDistanceKm(forCourseDistanceKm distanceKm: Double) -> Double? {
        let range = selectedSectionCourseRangeKm
        guard distanceKm >= range.lowerBound - 0.000_001,
              distanceKm <= range.upperBound + 0.000_001 else { return nil }
        return min(max(distanceKm - range.lowerBound, 0), range.upperBound - range.lowerBound)
    }

    func courseDistanceKm(forSelectedSectionLocalDistanceKm distanceKm: Double) -> Double {
        selectedSectionCourseStartKm + distanceKm
    }

    func mergeSelectedWithNext() {
        guard canMergeSelectedWithNext else { return }
        let old = takeSnapshot()
        let index = selectedSectionIndex
        var left = sections[index]
        let right = sections[index + 1]

        if left.routePoints.isEmpty {
            left.routePoints = right.routePoints
            left.legs = right.legs
            left.cuePoints = right.cuePoints
        } else if !right.routePoints.isEmpty {
            let leftDistanceMeters = left.distanceKm * 1000
            let from = left.routePoints[left.routePoints.count - 1]
            let to = right.routePoints[0]
            let bridgeDistanceKm = Geo.haversineKm(from.lat, from.lon, to.lat, to.lon)
            let bridge = CourseLeg(
                kind: .straight,
                trackPoints: [
                    TrackPointCodable(
                        lat: from.lat, lon: from.lon,
                        ele: left.trackPoints.last?.ele,
                        cumKm: 0
                    ),
                    TrackPointCodable(
                        lat: to.lat, lon: to.lon,
                        ele: right.trackPoints.first?.ele,
                        cumKm: bridgeDistanceKm
                    ),
                ]
            )
            left.routePoints.append(contentsOf: right.routePoints)
            left.legs.append(bridge)
            left.legs.append(contentsOf: right.legs)
            let cueOffset = leftDistanceMeters + bridgeDistanceKm * 1000
            left.cuePoints.append(contentsOf: right.cuePoints.map { cue in
                var copy = cue
                copy.distanceMeters += cueOffset
                return copy
            })
            left.cuePoints.sort { $0.distanceMeters < $1.distanceMeters }
        }

        sections[index] = left
        sections.remove(at: index + 1)
        selectedSectionID = left.id
        registerUndo(before: old, actionName: "섹션 합치기")
    }

    /// 활성 섹션을 지정한 로컬 누적 거리에서 둘로 나눈다.
    @discardableResult
    func splitSelectedSection(atDistanceKm distanceKm: Double) -> Bool {
        let index = selectedSectionIndex
        let section = sections[index]
        let epsilon = 0.000_001
        guard section.routePoints.count >= 2,
              distanceKm > epsilon,
              distanceKm < section.distanceKm - epsilon else { return false }

        var legStartKm = 0.0
        for legIndex in section.legs.indices {
            let leg = section.legs[legIndex]
            let legDistanceKm = Self.distanceKm(of: leg.trackPoints)
            let legEndKm = legStartKm + legDistanceKm

            if abs(distanceKm - legStartKm) <= epsilon, legIndex > 0 {
                split(section: section, sectionIndex: index, atRoutePoint: legIndex, distanceKm: distanceKm)
                return true
            }
            if abs(distanceKm - legEndKm) <= epsilon, legIndex + 1 < section.routePoints.count - 1 {
                split(section: section, sectionIndex: index, atRoutePoint: legIndex + 1, distanceKm: distanceKm)
                return true
            }
            if distanceKm > legStartKm, distanceKm < legEndKm,
               let splitLegs = Self.split(leg: leg, atDistanceKm: distanceKm - legStartKm) {
                let old = takeSnapshot()
                let splitPoint = splitLegs.point
                let leftRoutePoint = CourseRoutePoint(lat: splitPoint.lat, lon: splitPoint.lon)
                let rightRoutePoint = CourseRoutePoint(lat: splitPoint.lat, lon: splitPoint.lon)

                let left = CourseSection(
                    id: section.id,
                    routePoints: Array(section.routePoints.prefix(legIndex + 1)) + [leftRoutePoint],
                    legs: Array(section.legs.prefix(legIndex)) + [splitLegs.left],
                    cuePoints: section.cuePoints.filter { $0.distanceMeters < distanceKm * 1000 }
                )
                let right = CourseSection(
                    routePoints: [rightRoutePoint] + Array(section.routePoints.suffix(from: legIndex + 1)),
                    legs: [splitLegs.right] + Array(section.legs.suffix(from: legIndex + 1)),
                    cuePoints: shiftedRightCues(section.cuePoints, splitMeters: distanceKm * 1000)
                )
                sections[index] = left
                sections.insert(right, at: index + 1)
                selectedSectionID = right.id
                registerUndo(before: old, actionName: "섹션 분할")
                return true
            }
            legStartKm = legEndKm
        }
        return false
    }

    var allCourseTrackPoints: [TrackPoint] {
        var result: [TrackPoint] = []
        var offset = 0.0
        for section in sections {
            for point in section.trackPoints {
                result.append(TrackPoint(
                    lat: point.lat, lon: point.lon, ele: point.ele, time: point.time,
                    cumKm: offset + point.cumKm
                ))
            }
            offset += section.distanceKm
        }
        return result
    }

    var allCourseSectionTrackPoints: [[TrackPoint]] {
        var offset = 0.0
        return sections.map { section in
            let points = section.trackPoints.map { point in
                TrackPoint(
                    lat: point.lat, lon: point.lon, ele: point.ele, time: point.time,
                    cumKm: offset + point.cumKm
                )
            }
            offset += section.distanceKm
            return points
        }
    }

    var allCourseCuePoints: [CourseCuePoint] {
        var result: [CourseCuePoint] = []
        var offsetMeters = 0.0
        for section in sections {
            result.append(contentsOf: section.cuePoints.map { cue in
                var copy = cue
                copy.distanceMeters += offsetMeters
                return copy
            })
            offsetMeters += section.distanceKm * 1000
        }
        return result.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    private func replaceLegTrackPoints(_ points: [[TrackPointCodable]]) {
        var legs = sections[selectedSectionIndex].legs
        if legs.count == points.count {
            for index in points.indices { legs[index].trackPoints = points[index] }
        } else {
            legs = points.map { CourseLeg(kind: .routed, trackPoints: $0) }
        }
        sections[selectedSectionIndex].legs = legs
    }

    private func split(
        section: CourseSection,
        sectionIndex: Int,
        atRoutePoint routePointIndex: Int,
        distanceKm: Double
    ) {
        let old = takeSnapshot()
        var rightStart = section.routePoints[routePointIndex]
        rightStart.id = UUID()
        let left = CourseSection(
            id: section.id,
            routePoints: Array(section.routePoints.prefix(routePointIndex + 1)),
            legs: Array(section.legs.prefix(routePointIndex)),
            cuePoints: section.cuePoints.filter { $0.distanceMeters < distanceKm * 1000 }
        )
        let right = CourseSection(
            routePoints: [rightStart] + Array(section.routePoints.suffix(from: routePointIndex + 1)),
            legs: Array(section.legs.suffix(from: routePointIndex)),
            cuePoints: shiftedRightCues(section.cuePoints, splitMeters: distanceKm * 1000)
        )
        sections[sectionIndex] = left
        sections.insert(right, at: sectionIndex + 1)
        selectedSectionID = right.id
        registerUndo(before: old, actionName: "섹션 분할")
    }

    private func shiftedRightCues(_ cues: [CourseCuePoint], splitMeters: Double) -> [CourseCuePoint] {
        cues.filter { $0.distanceMeters >= splitMeters }.map { cue in
            var copy = cue
            copy.distanceMeters -= splitMeters
            return copy
        }
    }

    private static func distanceKm(of points: [TrackPointCodable]) -> Double {
        guard points.count > 1 else { return 0 }
        return (1 ..< points.count).reduce(0) { distance, index in
            let previous = points[index - 1]
            let current = points[index]
            return distance + Geo.haversineKm(previous.lat, previous.lon, current.lat, current.lon)
        }
    }

    private static func split(
        leg: CourseLeg,
        atDistanceKm targetKm: Double
    ) -> (left: CourseLeg, right: CourseLeg, point: TrackPointCodable)? {
        let points = leg.trackPoints
        guard points.count >= 2 else { return nil }
        var distance = 0.0
        for index in 1 ..< points.count {
            let previous = points[index - 1]
            let current = points[index]
            let segmentDistance = Geo.haversineKm(previous.lat, previous.lon, current.lat, current.lon)
            guard segmentDistance > 0 else { continue }
            if distance + segmentDistance >= targetKm {
                let fraction = min(1, max(0, (targetKm - distance) / segmentDistance))
                let elevation: Double? = {
                    guard let a = previous.ele, let b = current.ele else { return previous.ele ?? current.ele }
                    return a + (b - a) * fraction
                }()
                let point = TrackPointCodable(
                    lat: previous.lat + (current.lat - previous.lat) * fraction,
                    lon: previous.lon + (current.lon - previous.lon) * fraction,
                    ele: elevation,
                    cumKm: targetKm
                )
                let leftPoints: [TrackPointCodable]
                let rightPoints: [TrackPointCodable]
                if fraction >= 1 - 0.000_000_001 {
                    leftPoints = Array(points.prefix(index + 1))
                    rightPoints = Array(points.suffix(from: index)).enumerated().map { offset, value in
                        var copy = value
                        if offset == 0 { copy.cumKm = 0 }
                        return copy
                    }
                } else {
                    leftPoints = Array(points.prefix(index)) + [point]
                    rightPoints = [TrackPointCodable(lat: point.lat, lon: point.lon, ele: point.ele, cumKm: 0)]
                        + Array(points.suffix(from: index))
                }
                return (
                    CourseLeg(kind: leg.kind, trackPoints: leftPoints),
                    CourseLeg(kind: leg.kind, trackPoints: rightPoints),
                    point
                )
            }
            distance += segmentDistance
        }
        return nil
    }
}
