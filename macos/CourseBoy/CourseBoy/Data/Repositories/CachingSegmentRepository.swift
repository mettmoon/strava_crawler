import Foundation
import CourseBoyKit

actor CachingSegmentRepository: SegmentRepository {
    private static let currentSegmentsPath = "CourseBoy/segments"
    private static let legacySegmentsPath = "StravaTCX/segments"

    private var memoryCache: [String: SegmentInfo] = [:]
    private let storageDir: URL
    private let remoteService: any StravaRemoteService

    init(remoteService: any StravaRemoteService) {
        self.remoteService = remoteService
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent(Self.currentSegmentsPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storageDir = dir
        Self.migrateLegacySegments(into: dir)
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

    // MARK: - 마이그레이션

    /// 기존 앱명으로 저장된 JSON 파일을 새 캐시 위치로 1회 이전한다.
    private static func migrateLegacySegments(into newDir: URL) {
        let fm = FileManager.default
        if let cacheBase = fm.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let legacyCacheDir = cacheBase.appendingPathComponent(legacySegmentsPath, isDirectory: true)
            moveSegmentFiles(from: legacyCacheDir, into: newDir)
        }
        if let appSupportBase = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let legacyAppSupportDir = appSupportBase.appendingPathComponent(legacySegmentsPath, isDirectory: true)
            moveSegmentFiles(from: legacyAppSupportDir, into: newDir)
        }
    }

    private static func moveSegmentFiles(from legacyDir: URL, into newDir: URL) {
        let fm = FileManager.default
        guard legacyDir.path != newDir.path else { return }
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
