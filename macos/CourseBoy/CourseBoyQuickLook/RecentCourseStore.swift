import CoursePreviewCore
import CryptoKit
import Foundation
import Observation

/// 홈 화면에 보여줄 최근 연 코스. 원본을 다시 파싱하지 않고 카드를 그리도록 요약을 함께 저장한다.
struct RecentCourse: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var fileName: String
    var fileKind: String
    var lastOpenedAt: Date
    var isFavorite: Bool
    var distanceKm: Double
    var ascentMeters: Double?
    /// 거리 기준으로 고르게 뽑은 고도. 고도 데이터가 없는 파일은 비어 있다.
    var elevationProfile: [Double]
    /// 썸네일에 그릴 경로 모양. 가로세로 비율을 지킨 채 0...1 정사각형 안에 가운데 맞춰 둔 좌표라
    /// 카드는 크기만 곱해 바로 그린다. 트랙 포인트를 몇백 개로 솎아 둔다.
    var routeShape: [RouteShapePoint]
    /// 파일 내용의 SHA-256. 같은 코스를 다른 경로로 열어도 한 항목으로 묶는다.
    var contentHash: String
    /// 북마크로 연 원본 파일 경로. 같은 파일을 다시 열었는지 가린다.
    var sourcePath: String?
    /// 원본 파일의 보안 범위 북마크. 앱 안에 사본을 둔 항목은 nil.
    var bookmark: Data?
    /// 북마크를 만들 수 없어 앱 안에 둔 사본의 경로. 원래 파일 이름을 지키도록 "<UUID>/<파일 이름>"으로 둔다.
    var libraryFileName: String?
}

/// 정사각형 경로 모양의 한 점. x는 오른쪽, y는 아래쪽으로 커진다.
struct RouteShapePoint: Codable, Equatable {
    var x: Double
    var y: Double
}

enum RecentCourseError: LocalizedError {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "파일이 옮겨졌거나 지워졌을 수 있습니다."
        }
    }
}

/// 최근 연 코스와 즐겨찾기. 모든 창이 같은 목록을 보도록 앱에 하나만 둔다.
@MainActor
@Observable
final class RecentCourseStore {
    static let shared = RecentCourseStore()

    private(set) var courses: [RecentCourse] = []
    /// 원본에 접근할 수 없어 흐리게 보여줄 항목.
    private(set) var missingIDs: Set<UUID> = []

    private init() {
        let (courses, didMigrate) = Self.loadCourses()
        self.courses = courses
        if didMigrate {
            save()
        }
    }

    // MARK: - Recording

    /// 연 코스를 최근 목록 맨 앞에 기록한다. 같은 파일이나 같은 내용이면 기존 항목을 갱신한다.
    /// - Parameter isLibraryCopy: url이 이미 앱 안 사본이면 true. 드롭처럼 원본 위치를 알 수 없는 경우다.
    @discardableResult
    func record(_ file: ReadCourseFile, from url: URL, isLibraryCopy: Bool = false) -> RecentCourse.ID {
        let hash = Self.contentHash(of: file.data)
        let existingIndex = courses.firstIndex { course in
            (!isLibraryCopy && course.sourcePath == url.standardizedFileURL.path) || course.contentHash == hash
        }

        var location = isLibraryCopy ? Location.library(Self.libraryPath(of: url)) : Self.makeLocation(for: url)
        // 이미 저장해 둔 사본을 다시 연 경우(newCopy가 기존 사본)는 그대로 둔다.
        if let existingIndex, case .library(let newCopy) = location, newCopy != courses[existingIndex].libraryFileName {
            let existing = courses[existingIndex]
            if existing.libraryFileName != nil || (existing.bookmark != nil && !missingIDs.contains(existing.id)) {
                // 이미 열 수 있는 원본이나 사본이 있으면 새로 만든 사본은 버린다.
                Self.removeLibraryFile(named: newCopy)
                location = existing.libraryFileName.map(Location.library)
                    ?? .bookmark(existing.bookmark!, path: existing.sourcePath)
            }
        }

        var course = RecentCourse(
            id: existingIndex.map { courses[$0].id } ?? UUID(),
            title: file.course.title,
            fileName: url.lastPathComponent,
            fileKind: file.course.fileKind.rawValue,
            lastOpenedAt: .now,
            isFavorite: existingIndex.map { courses[$0].isFavorite } ?? false,
            distanceKm: file.course.totalDistanceKm,
            ascentMeters: file.course.elevationStats.ascent,
            elevationProfile: Self.elevationProfile(of: file.course),
            routeShape: Self.routeShape(of: file.course),
            contentHash: hash
        )
        switch location {
        case .bookmark(let bookmark, let path):
            course.bookmark = bookmark
            course.sourcePath = path
        case .library(let name):
            course.libraryFileName = name
        }

        if let existingIndex {
            let previous = courses.remove(at: existingIndex)
            if let oldCopy = previous.libraryFileName, oldCopy != course.libraryFileName {
                Self.removeLibraryFile(named: oldCopy)
            }
        }
        courses.insert(course, at: 0)
        missingIDs.remove(course.id)
        save()
        return course.id
    }

    /// 앱 밖에서 받은 임시 파일을 앱 안으로 복사한다. 드롭으로 받은 파일은 가져오기가 끝나면 지워진다.
    nonisolated static func copyIntoLibrary(_ url: URL) throws -> URL {
        let directory = libraryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    /// 사본 URL에서 "<UUID>/<파일 이름>" 꼴의 저장 경로를 뽑는다.
    nonisolated private static func libraryPath(of url: URL) -> String {
        "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent)"
    }

    // MARK: - Opening

    /// 최근 항목을 다시 연다. 열 수 없으면 흐리게 표시하도록 표시해 두고 오류를 던진다.
    func open(_ id: RecentCourse.ID) async throws -> LoadedCourse {
        guard let course = courses.first(where: { $0.id == id }) else { throw RecentCourseError.notFound }
        do {
            let url = try resolveURL(of: course)
            let file = try await CourseFileReader.read(url)
            // 기록은 사본 여부를 그대로 유지한 채 요약과 열람 시각을 갱신한다.
            record(file, from: url, isLibraryCopy: course.libraryFileName != nil)
            return file.course
        } catch {
            missingIDs.insert(id)
            throw RecentCourseError.notFound
        }
    }

    /// 원본에 접근할 수 있는지 다시 확인해 흐리게 보여줄 항목을 고른다.
    func refreshAvailability() async {
        let snapshot = courses
        let missing = await Task.detached(priority: .utility) {
            Set(snapshot.filter { !Self.isReachable($0) }.map(\.id))
        }.value
        missingIDs = missing
    }

    /// 공유 시트에 넘길 임시 사본. 보안 범위 원본은 공유 시트가 접근할 수 없어 임시 폴더로 복사한다.
    func shareableURL(for id: RecentCourse.ID) async throws -> URL {
        guard let course = courses.first(where: { $0.id == id }) else { throw RecentCourseError.notFound }
        let source = try resolveURL(of: course)
        let fileName = course.fileName
        return try await Task.detached(priority: .userInitiated) {
            let file = try CourseFileReader.readSynchronously(source)
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Share", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(fileName)
            try file.data.write(to: destination)
            return destination
        }.value
    }

    // MARK: - Editing

    func setFavorite(_ id: RecentCourse.ID, _ isFavorite: Bool) {
        guard let index = courses.firstIndex(where: { $0.id == id }) else { return }
        courses[index].isFavorite = isFavorite
        save()
    }

    func remove(_ id: RecentCourse.ID) {
        guard let index = courses.firstIndex(where: { $0.id == id }) else { return }
        discardFiles(of: courses.remove(at: index))
        missingIDs.remove(id)
        save()
    }

    /// 즐겨찾기를 뺀 최근 기록을 모두 지운다. 원본 파일은 건드리지 않는다.
    func removeAllRecents() {
        for course in courses where !course.isFavorite {
            discardFiles(of: course)
            missingIDs.remove(course.id)
        }
        courses.removeAll { !$0.isFavorite }
        save()
    }

    private func discardFiles(of course: RecentCourse) {
        if let name = course.libraryFileName {
            Self.removeLibraryFile(named: name)
        }
    }

    // MARK: - Locations

    private enum Location {
        case bookmark(Data, path: String?)
        case library(String)
    }

    /// 원본을 가리키는 북마크를 만든다. 만들 수 없으면 앱 안에 사본을 둔다.
    private static func makeLocation(for url: URL) -> Location {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        if let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            return .bookmark(bookmark, path: url.standardizedFileURL.path)
        }
        if let copy = try? copyIntoLibrary(url) {
            return .library(libraryPath(of: copy))
        }
        return .bookmark(Data(), path: url.standardizedFileURL.path)
    }

    private func resolveURL(of course: RecentCourse) throws -> URL {
        if let name = course.libraryFileName {
            return Self.libraryDirectory.appendingPathComponent(name)
        }
        guard let bookmark = course.bookmark, !bookmark.isEmpty else { throw RecentCourseError.notFound }
        var isStale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
        if isStale, let index = courses.firstIndex(where: { $0.id == course.id }) {
            let accessed = url.startAccessingSecurityScopedResource()
            if let refreshed = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                courses[index].bookmark = refreshed
                courses[index].sourcePath = url.standardizedFileURL.path
                save()
            }
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        return url
    }

    nonisolated private static func isReachable(_ course: RecentCourse) -> Bool {
        if let name = course.libraryFileName {
            return FileManager.default.fileExists(atPath: libraryDirectory.appendingPathComponent(name).path)
        }
        guard let bookmark = course.bookmark, !bookmark.isEmpty else { return false }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return false
        }
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }
        // 아직 내려받지 않은 iCloud 파일도 자리는 남아 있으므로 존재하는 것으로 본다.
        return FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Summary

    private static let elevationSampleCount = 60
    private static let routeShapePointLimit = 400

    private static func elevationProfile(of course: LoadedCourse) -> [Double] {
        let points = course.trackPoints.filter { $0.ele != nil }
        guard points.count >= 2, let total = points.last?.cumKm, total > 0 else { return [] }
        var samples: [Double] = []
        samples.reserveCapacity(elevationSampleCount)
        var index = 0
        for step in 0..<elevationSampleCount {
            let target = total * Double(step) / Double(elevationSampleCount - 1)
            while index < points.count - 1, points[index].cumKm < target {
                index += 1
            }
            samples.append(points[index].ele ?? 0)
        }
        return samples
    }

    private static func routeShape(of course: LoadedCourse) -> [RouteShapePoint] {
        let points = course.trackPoints
        guard !points.isEmpty else {
            return normalizedShape(lats: course.routePoints.map(\.lat), lons: course.routePoints.map(\.lon))
        }
        let stride = max(1, points.count / routeShapePointLimit)
        var indices = Array(Swift.stride(from: 0, to: points.count, by: stride))
        if indices.last != points.count - 1 {
            indices.append(points.count - 1)
        }
        return normalizedShape(lats: indices.map { points[$0].lat }, lons: indices.map { points[$0].lon })
    }

    /// 위경도를 비율을 지킨 채 0...1 정사각형 안에 가운데 맞춘다.
    /// 위도가 높을수록 경도 간격이 좁아지는 것만 보정하는 간단한 투영이라 썸네일 크기에서는 충분하다.
    nonisolated static func normalizedShape(lats: [Double], lons: [Double]) -> [RouteShapePoint] {
        guard let firstLat = lats.first else { return [] }
        let lonScale = cos(firstLat * .pi / 180)
        let xs = lons.map { $0 * lonScale }
        guard let minX = xs.min(), let maxX = xs.max(), let minLat = lats.min(), let maxLat = lats.max() else {
            return []
        }
        let span = max(maxX - minX, maxLat - minLat, 1e-9)
        let offsetX = (1 - (maxX - minX) / span) / 2
        let offsetY = (1 - (maxLat - minLat) / span) / 2
        return zip(xs, lats).map { x, lat in
            RouteShapePoint(x: offsetX + (x - minX) / span, y: offsetY + (maxLat - lat) / span)
        }
    }

    private static func contentHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Persistence

    nonisolated private static var baseDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("RecentCourses", isDirectory: true)
    }

    nonisolated private static var libraryDirectory: URL {
        baseDirectory.appendingPathComponent("Files", isDirectory: true)
    }

    nonisolated private static var indexURL: URL {
        baseDirectory.appendingPathComponent("recents.json")
    }

    /// 사본과 그 사본을 담은 UUID 폴더를 함께 지운다.
    nonisolated private static func removeLibraryFile(named name: String) {
        let file = libraryDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private static func loadCourses() -> (courses: [RecentCourse], didMigrate: Bool) {
        // 지도 스냅샷 썸네일을 쓰던 때의 이미지 캐시는 더 쓰지 않으므로 지운다.
        try? FileManager.default.removeItem(
            at: URL.cachesDirectory.appendingPathComponent("CourseThumbnails", isDirectory: true)
        )
        guard let data = try? Data(contentsOf: indexURL) else { return ([], false) }
        let migrated = migratedIndex(data)
        let courses = (try? JSONDecoder().decode([RecentCourse].self, from: migrated ?? data)) ?? []
        return (courses, migrated != nil)
    }

    /// 위경도 미리보기(routePreview)로 저장한 예전 항목을 정사각형 경로 모양(routeShape)으로 바꾼다.
    /// 바꿀 항목이 없으면 nil.
    private static func migratedIndex(_ data: Data) -> Data? {
        guard var entries = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
              entries.contains(where: { $0["routeShape"] == nil }) else {
            return nil
        }
        for index in entries.indices where entries[index]["routeShape"] == nil {
            let preview = entries[index]["routePreview"] as? [[String: Double]] ?? []
            let shape = normalizedShape(
                lats: preview.compactMap { $0["lat"] },
                lons: preview.compactMap { $0["lon"] }
            )
            entries[index]["routeShape"] = shape.map { ["x": $0.x, "y": $0.y] }
            entries[index]["routePreview"] = nil
        }
        return try? JSONSerialization.data(withJSONObject: entries)
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.baseDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(courses)
            try data.write(to: Self.indexURL, options: .atomic)
        } catch {
            assertionFailure("최근 코스 목록을 저장하지 못했습니다: \(error)")
        }
    }
}
