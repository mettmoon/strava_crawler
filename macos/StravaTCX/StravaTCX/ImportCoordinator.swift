import Foundation
import Observation
import SwiftData
import StravaTCXKit

/// 라우트 추가 파이프라인(원본 TCX 다운로드 + 세그먼트 수집)을 백그라운드로 돌리는 조정자.
///
/// 진행률·상태 메시지는 영속하지 않고 레코드별로 메모리에 들고 있다가, 끝나면 레코드에
/// 결과(원본 TCX·세그먼트·카운트·상태)만 기록한다.
@MainActor
@Observable
final class ImportCoordinator {

    /// 한 레코드의 진행 상태(인메모리).
    struct Progress {
        var fraction: Double?   // nil = 비결정(스피너)
        var message: String
    }

    /// 레코드 인스턴스별 진행 상태. 처리 끝나면 제거.
    private(set) var imports: [ObjectIdentifier: Progress] = [:]

    private let ds: StravaDataSource = LiveDataSource()
    /// 인메모리 캐시 (이번 세션 안에서 중복 요청 방지)
    private var segmentCache: [String: SegmentInfo] = [:]

    // MARK: - 디스크 캐시

    /// 캐시 저장 디렉토리: ~/Library/Caches/StravaTCX/segments/
    private static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("StravaTCX/segments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func cacheFile(for segmentID: String) -> URL {
        cacheDir.appendingPathComponent("\(segmentID).json")
    }

    /// 디스크에서 SegmentInfo 로드. 없거나 손상되면 nil.
    private static func loadFromDisk(segmentID: String) -> SegmentInfo? {
        let file = cacheFile(for: segmentID)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(SegmentInfo.self, from: data)
    }

    /// SegmentInfo 를 디스크에 저장.
    private static func saveToDisk(_ info: SegmentInfo) {
        guard let data = try? JSONEncoder().encode(info) else { return }
        try? data.write(to: cacheFile(for: info.segmentID), options: .atomic)
    }

    func progress(for record: RouteRecord) -> Progress? {
        imports[ObjectIdentifier(record)]
    }

    // MARK: - 추가 / 재시도

    /// ‘내 경로’에서 고른 항목을 새 레코드로 만들어 즉시 목록에 넣고, 백그라운드 처리를 시작한다.
    @discardableResult
    func importRoute(_ route: MyRoute, into context: ModelContext) -> RouteRecord {
        let title = route.name.isEmpty ? "Route \(route.id)" : route.name
        let record = RouteRecord(
            routeID: route.id, title: title, createdAt: Date(), status: .processing
        )
        context.insert(record)
        run(record)
        return record
    }

    /// 실패한 레코드를 다시 처리한다.
    func retry(_ record: RouteRecord) {
        guard record.status != .processing else { return }
        record.status = .processing
        record.errorMessage = nil
        run(record)
    }

    /// TCX 를 강제로 다시 다운로드하여 기존 데이터를 덮어씌운다 (세그먼트 캐시는 유지).
    func redownload(_ record: RouteRecord) {
        guard record.status != .processing else { return }
        record.status = .processing
        record.errorMessage = nil
        run(record)
    }

    /// 앱 종료 등으로 중단된 채 남은 processing 레코드를 failed 로 정리한다.
    func reconcileOnLaunch(context: ModelContext) {
        let descriptor = FetchDescriptor<RouteRecord>(
            predicate: #Predicate { $0.statusRaw == "processing" }
        )
        guard let stuck = try? context.fetch(descriptor) else { return }
        for record in stuck where progress(for: record) == nil {
            record.status = .failed
            record.errorMessage = "처리가 중단되었습니다. 다시 시도하세요."
        }
    }

    // MARK: - 파이프라인

    private func run(_ record: RouteRecord) {
        Task { await pipeline(record) }
    }

    private func pipeline(_ record: RouteRecord) async {
        let key = ObjectIdentifier(record)
        let cookie = AppSettings.cookie
        imports[key] = Progress(fraction: nil, message: "TCX 다운로드 중…")
        defer { imports[key] = nil }

        do {
            // 1) 원본 TCX
            let data = try await ds.downloadTCX(routeID: record.routeID, cookie: cookie)
            let course = try TCXCourse(data: data)
            if let name = course.courseName, !name.isEmpty,
               record.title.hasPrefix("Route ") {
                record.title = name
            }

            // 2) 세그먼트
            imports[key] = Progress(fraction: 0, message: "세그먼트 목록 가져오는 중…")
            let ids = try await ds.fetchSegmentIDs(routeID: record.routeID, cookie: cookie)
            // 429(요청 과다) 회피용 요청 간격. 캐시에 없어 실제로 네트워크 요청할 때만 대기.
            let interval = AppSettings.segmentRequestInterval
            var didFetch = false
            var segments: [SegmentInfo] = []
            for (i, id) in ids.enumerated() {
                var info: SegmentInfo
                if let cached = segmentCache[id] {
                    // 1순위: 인메모리 캐시
                    info = cached
                } else if let onDisk = Self.loadFromDisk(segmentID: id) {
                    // 2순위: 디스크 캐시
                    info = onDisk
                    segmentCache[id] = onDisk
                } else {
                    // 네트워크 요청
                    if didFetch, interval > 0 {
                        try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                    }
                    didFetch = true
                    imports[key] = Progress(
                        fraction: Double(i) / Double(max(ids.count, 1)),
                        message: "세그먼트 \(i + 1)/\(ids.count)…"
                    )
                    info = try await ds.fetchSegment(id: id, cookie: cookie)
                    segmentCache[id] = info
                    Self.saveToDisk(info)
                }
                info.order = i + 1
                segments.append(info)
            }

            // 3) 결과 기록 (CoursePoint·내보낼 TCX 는 상세화면에서 즉석 생성)
            record.tcxData = data
            record.segments = segments
            record.trackPointCount = course.trackPoints.count
            record.coursePointCount = Cuesheet.makeEntries(
                trackPoints: course.trackPoints, segments: segments, minCategory: record.minCategory
            ).entries.count
            record.errorMessage = nil
            record.status = .ready
        } catch {
            record.status = .failed
            record.errorMessage = error.localizedDescription
        }
    }
}
