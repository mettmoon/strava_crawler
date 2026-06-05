import Foundation
import StravaTCXKit

actor CachingSegmentRepository: SegmentRepository {
    private var memoryCache: [String: SegmentInfo] = [:]
    private let cacheDir: URL
    private let remoteService: any StravaRemoteService

    init(remoteService: any StravaRemoteService) {
        self.remoteService = remoteService
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("StravaTCX/segments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheDir = dir
    }

    func fetch(id: String) async throws -> SegmentInfo? {
        if let hit = memoryCache[id] { return hit }
        if let disk = loadFromDisk(id: id) {
            memoryCache[id] = disk
            return disk
        }
        return nil
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
        try? FileManager.default.removeItem(at: cacheFile(for: id))
    }

    // MARK: - 디스크 캐시

    private func cacheFile(for id: String) -> URL {
        cacheDir.appendingPathComponent("\(id).json")
    }

    private func loadFromDisk(id: String) -> SegmentInfo? {
        guard let data = try? Data(contentsOf: cacheFile(for: id)) else { return nil }
        return try? JSONDecoder().decode(SegmentInfo.self, from: data)
    }

    private func saveToDisk(_ segment: SegmentInfo) {
        guard let data = try? JSONEncoder().encode(segment) else { return }
        try? data.write(to: cacheFile(for: segment.segmentID), options: .atomic)
    }
}
