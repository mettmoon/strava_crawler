import Foundation
import StravaTCXKit

actor CachingSegmentRepository: SegmentRepository {
    private var memoryCache: [String: SegmentInfo] = [:]
    private let storageDir: URL
    private let remoteService: any StravaRemoteService

    init(remoteService: any StravaRemoteService) {
        self.remoteService = remoteService
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("StravaTCX/segments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageDir = dir
        Self.migrateLegacyCache(into: dir)
    }

    func fetch(id: String) async throws -> SegmentInfo? {
        if let hit = memoryCache[id] { return hit }
        if let disk = loadFromDisk(id: id) {
            memoryCache[id] = disk
            return disk
        }
        return nil
    }

    func fetchAll() async throws -> [SegmentInfo] {
        var result: [String: SegmentInfo] = memoryCache
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: storageDir, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "json" {
            let id = url.deletingPathExtension().lastPathComponent
            if result[id] != nil { continue }
            guard let data = try? Data(contentsOf: url),
                  let seg = try? JSONDecoder().decode(SegmentInfo.self, from: data) else { continue }
            result[id] = seg
            memoryCache[id] = seg
        }
        return result.values.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func fetchOrDownload(id: String, credentials: Credentials) async throws -> SegmentInfo {
        if let cached = try await fetch(id: id) { return cached }
        let seg = try await remoteService.fetchSegment(id: id, credentials: credentials)
        memoryCache[id] = seg
        saveToDisk(seg)
        return seg
    }

    func save(_ segment: SegmentInfo) async throws {
        memoryCache[segment.segmentID] = segment
        saveToDisk(segment)
    }

    func invalidate(id: String) async throws {
        memoryCache.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: storageFile(for: id))
    }

    // MARK: - 디스크 저장

    private func storageFile(for id: String) -> URL {
        storageDir.appendingPathComponent("\(id).json")
    }

    private func loadFromDisk(id: String) -> SegmentInfo? {
        guard let data = try? Data(contentsOf: storageFile(for: id)) else { return nil }
        return try? JSONDecoder().decode(SegmentInfo.self, from: data)
    }

    private func saveToDisk(_ segment: SegmentInfo) {
        guard let data = try? JSONEncoder().encode(segment) else { return }
        try? data.write(to: storageFile(for: segment.segmentID), options: .atomic)
    }

    // MARK: - 레거시 마이그레이션

    /// `~/Library/Caches/StravaTCX/segments/`에 있던 JSON 파일을
    /// 새 위치(Application Support)로 1회 이전한다. 모두 옮긴 뒤 빈 디렉터리는 제거.
    private static func migrateLegacyCache(into newDir: URL) {
        let fm = FileManager.default
        guard let cachesBase = fm.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let legacyDir = cachesBase.appendingPathComponent("StravaTCX/segments", isDirectory: true)
        guard fm.fileExists(atPath: legacyDir.path) else { return }

        let urls = (try? fm.contentsOfDirectory(at: legacyDir, includingPropertiesForKeys: nil)) ?? []
        for url in urls where url.pathExtension == "json" {
            let dst = newDir.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dst.path) {
                try? fm.removeItem(at: url)
            } else {
                try? fm.moveItem(at: url, to: dst)
            }
        }
        try? fm.removeItem(at: legacyDir)
    }
}
