import Foundation
import Observation
import StravaTCXKit

/// 라우트 추가 위저드의 상태/로직.
@MainActor
@Observable
final class AppModel {

    enum Step: Int, CaseIterable, Identifiable {
        case route, download, segments, coursePoints, save
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .route: return "라우트"
            case .download: return "TCX 다운로드"
            case .segments: return "세그먼트"
            case .coursePoints: return "CoursePoint"
            case .save: return "저장"
            }
        }

        var systemImage: String {
            switch self {
            case .route: return "number"
            case .download: return "arrow.down.circle.fill"
            case .segments: return "list.bullet.rectangle.fill"
            case .coursePoints: return "mappin.and.ellipse"
            case .save: return "tray.and.arrow.down.fill"
            }
        }
    }

    // 입력
    var routeID = "" { didSet { if oldValue != routeID { resetDownstream() } } }
    var minCategory: String? = nil   // nil = 전체

    // 쿠키는 전역 설정(설정 화면)에서 가져온다.
    private var cookie: String { AppSettings.cookie }

    // 내비게이션
    var step: Step = .route

    // 진행 상태
    var isBusy = false
    var progress: Double?
    var statusMessage = ""
    var errorMessage: String?

    // 데이터
    var tcxData: Data?
    var course: TCXCourse?
    var segments: [SegmentInfo] = []
    var entries: [CoursePointEntry] = []

    /// 저장 완료 콜백 (부모가 modelContext 에 삽입).
    var onComplete: ((RouteRecord) -> Void)?

    // 데이터 소스 + 캐시
    private let ds: StravaDataSource = LiveDataSource()
    private var segmentCache: [String: SegmentInfo] = [:]

    init() {}

    var trackPointCount: Int { course?.trackPoints.count ?? 0 }

    private func resetDownstream() {
        tcxData = nil
        course = nil
        segments = []
        entries = []
        statusMessage = ""
    }

    // MARK: - 단계별 primary 액션

    var primaryTitle: String {
        switch step {
        case .route: return "다음"
        case .download: return tcxData == nil ? "TCX 다운로드" : "다음"
        case .segments: return segments.isEmpty ? "세그먼트 불러오기" : "다음"
        case .coursePoints: return entries.isEmpty ? "CoursePoint 생성" : "다음"
        case .save: return "목록에 저장"
        }
    }

    var primaryEnabled: Bool {
        if isBusy { return false }
        switch step {
        case .route:
            return !routeID.trimmingCharacters(in: .whitespaces).isEmpty
        case .download, .segments, .coursePoints, .save:
            return true
        }
    }

    var canGoBack: Bool { step != .route && !isBusy }

    func back() {
        guard canGoBack, let prev = Step(rawValue: step.rawValue - 1) else { return }
        errorMessage = nil
        step = prev
    }

    func performPrimary() async {
        errorMessage = nil
        switch step {
        case .route:
            advance()
        case .download:
            if tcxData == nil { await runDownload() } else { advance() }
        case .segments:
            if segments.isEmpty { await runSegments() } else { advance() }
        case .coursePoints:
            if entries.isEmpty { runCoursePoints() } else { advance() }
        case .save:
            if let record = makeRecord() { onComplete?(record) }
        }
    }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else { return }
        statusMessage = ""
        step = next
    }

    // MARK: - 액션 구현

    private func runDownload() async {
        isBusy = true; progress = nil; statusMessage = "TCX 다운로드 중…"
        defer { isBusy = false }
        do {
            let data = try await ds.downloadTCX(routeID: routeID, cookie: cookie)
            let course = try TCXCourse(data: data)
            self.tcxData = data
            self.course = course
            statusMessage = "trackpoint \(course.trackPoints.count)개"
            advance()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = ""
        }
    }

    private func runSegments() async {
        isBusy = true; progress = 0; statusMessage = "세그먼트 목록 가져오는 중…"
        defer { isBusy = false; progress = nil }
        do {
            let ids = try await ds.fetchSegmentIDs(routeID: routeID, cookie: cookie)
            var result: [SegmentInfo] = []
            for (i, id) in ids.enumerated() {
                progress = Double(i) / Double(max(ids.count, 1))
                var info: SegmentInfo
                if let cached = segmentCache[id] {
                    info = cached
                } else {
                    statusMessage = "세그먼트 \(i + 1)/\(ids.count) (\(id))…"
                    info = try await ds.fetchSegment(id: id, cookie: cookie)
                    segmentCache[id] = info
                }
                info.order = i + 1
                result.append(info)
            }
            progress = 1
            segments = result
            statusMessage = "\(result.count)개 세그먼트"
            advance()
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = ""
        }
    }

    private func runCoursePoints() {
        guard let course else { errorMessage = "TCX 가 없습니다."; return }
        entries = Cuesheet.makeEntries(
            trackPoints: course.trackPoints, segments: segments, minCategory: minCategory
        ).entries
        statusMessage = "\(entries.count)개 CoursePoint"
        advance()
    }

    /// min-category 변경 시 CoursePoint 재생성 (이미 생성된 경우).
    func regenerateCoursePointsIfNeeded() {
        guard let course, !entries.isEmpty else { return }
        entries = Cuesheet.makeEntries(
            trackPoints: course.trackPoints, segments: segments, minCategory: minCategory
        ).entries
        statusMessage = "\(entries.count)개 CoursePoint"
    }

    // MARK: - 레코드 생성

    func makeRecord() -> RouteRecord? {
        guard let course else { errorMessage = "TCX 가 없습니다."; return nil }
        guard let cued = try? course.build(entries: entries, forRWGPS: false),
              let rwgps = try? course.build(entries: entries, forRWGPS: true) else {
            errorMessage = "TCX 생성에 실패했습니다."
            return nil
        }
        let storedSegments = segments.map {
            StoredSegment(order: $0.order, name: $0.name, category: $0.climbCategory,
                          distance: $0.distanceText, grade: $0.avgGrade)
        }
        let storedCoursePoints = entries.sorted { $0.idx < $1.idx }.map {
            StoredCoursePoint(isStart: $0.isStart, pointType: $0.pointType, notes: previewNotes(for: $0))
        }
        let rid = routeID.trimmingCharacters(in: .whitespaces)
        let title = "Route \(rid)"
        return RouteRecord(
            routeID: rid, title: title, createdAt: Date(),
            minCategory: minCategory, trackPointCount: course.trackPoints.count,
            coursePointCount: cued.count, cuedTCX: cued.data, rwgpsTCX: rwgps.data,
            segments: storedSegments, coursePoints: storedCoursePoints
        )
    }

    // MARK: - 프리뷰 헬퍼

    func previewNotes(for e: CoursePointEntry) -> String {
        if e.isStart {
            let body = [Classification.normalizeDistanceText(e.dist), Classification.formatGrade(e.grade)]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            return e.gradeClass.arrow + body
        } else {
            return "🏁" + Classification.resolveSegmentName(e.segName)
        }
    }
}
