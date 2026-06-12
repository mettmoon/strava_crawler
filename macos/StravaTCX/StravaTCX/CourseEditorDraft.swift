import Foundation
import StravaTCXKit

/// 코스 편집 세션의 로컬 작업 복사본.
/// SwiftData 모델을 직접 건드리지 않고, 저장 시에만 CourseRecord에 커밋한다.
/// 모든 변경은 snapshot 기반 undo/redo를 지원한다.
@Observable
final class CourseEditorDraft {
    var routePoints: [CourseRoutePoint]
    var trackSegments: [[TrackPointCodable]]
    var cuePoints: [CourseCuePoint]
    var title: String

    let undoManager = UndoManager()

    /// UndoManager의 canUndo/canRedo는 KVO/Notification으로만 갱신되므로
    /// SwiftUI 버튼 disabled 상태를 위해 수동으로 관리하는 트리거.
    var undoCount: Int = 0  // undo/redo 호출 시 토글해 View를 재렌더링

    private var notificationObservers: [NSObjectProtocol] = []

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    init(from course: CourseRecord) {
        routePoints = course.routePoints
        trackSegments = course.trackSegments
        cuePoints = course.cuePoints.sorted { $0.distanceMeters < $1.distanceMeters }
        title = course.title

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

    /// 전체 트랙포인트 (모든 구간 이어붙임, 구간 이음새 중복 제거 후 cumKm 재계산).
    /// `CourseRecord.allTrackPoints`와 동일한 규칙.
    var allTrackPoints: [TrackPoint] {
        var raw: [TrackPointCodable] = []
        for (segIdx, seg) in trackSegments.enumerated() {
            let slice = segIdx == 0 ? seg : Array(seg.dropFirst())
            raw.append(contentsOf: slice)
        }
        var result: [TrackPoint] = []
        var cumKm: Double = 0
        for (i, tp) in raw.enumerated() {
            if i > 0 {
                let prev = raw[i - 1]
                cumKm += Geo.haversineKm(prev.lat, prev.lon, tp.lat, tp.lon)
            }
            result.append(TrackPoint(lat: tp.lat, lon: tp.lon, ele: tp.ele, time: nil, cumKm: cumKm))
        }
        return result
    }

    /// 현재 draft 상태를 SwiftData 모델에 반영한다.
    func commit(to course: CourseRecord) {
        course.routePoints = routePoints
        course.trackSegments = trackSegments
        course.cuePoints = cuePoints
        course.title = title
    }

    // MARK: - Snapshot undo

    private struct Snapshot {
        let routePoints: [CourseRoutePoint]
        let trackSegments: [[TrackPointCodable]]
        let cuePoints: [CourseCuePoint]
    }

    private func takeSnapshot() -> Snapshot {
        Snapshot(routePoints: routePoints, trackSegments: trackSegments, cuePoints: cuePoints)
    }

    private func restore(_ s: Snapshot) {
        routePoints = s.routePoints
        trackSegments = s.trackSegments
        cuePoints = s.cuePoints
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

    // MARK: - RoutePoint 변경

    func appendRoutePoint(_ rp: CourseRoutePoint) {
        let old = takeSnapshot()
        routePoints.append(rp)
        registerUndo(before: old, actionName: "RoutePoint 추가")
    }

    func appendLastSegment(_ seg: [TrackPointCodable]) {
        let old = takeSnapshot()
        trackSegments.append(seg)
        registerUndo(before: old, actionName: "경로 추가")
    }

    /// RoutePoint 추가 + 구간을 하나의 undo 작업으로 묶는다.
    func appendRoutePoint(_ rp: CourseRoutePoint, segment: [TrackPointCodable]) {
        let old = takeSnapshot()
        routePoints.append(rp)
        trackSegments.append(segment)
        registerUndo(before: old, actionName: "RoutePoint 추가")
    }

    func removeRoutePoint(at idx: Int) {
        let old = takeSnapshot()
        routePoints.remove(at: idx)
        if routePoints.count <= 1 {
            trackSegments = []
        } else {
            let segIdx = max(0, idx - 1)
            if segIdx < trackSegments.count { trackSegments.remove(at: segIdx) }
        }
        registerUndo(before: old, actionName: "RoutePoint 삭제")
    }

    func moveRoutePoint(at idx: Int, to newRP: CourseRoutePoint, updatedSegments: [[TrackPointCodable]]) {
        let old = takeSnapshot()
        routePoints[idx] = newRP
        trackSegments = updatedSegments
        registerUndo(before: old, actionName: "RoutePoint 이동")
    }

    func replaceSegments(_ newSegments: [[TrackPointCodable]]) {
        let old = takeSnapshot()
        trackSegments = newSegments
        registerUndo(before: old, actionName: "경로 재계산")
    }

    // MARK: - CuePoint 변경

    func appendCuePoint(_ cue: CourseCuePoint) {
        let old = takeSnapshot()
        cuePoints.append(cue)
        cuePoints.sort { $0.distanceMeters < $1.distanceMeters }
        registerUndo(before: old, actionName: "큐시트 추가")
    }

    func removeCuePoints(at offsets: IndexSet) {
        let old = takeSnapshot()
        cuePoints.remove(atOffsets: offsets)
        registerUndo(before: old, actionName: "큐시트 삭제")
    }
}
