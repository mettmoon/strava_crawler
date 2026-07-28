import Foundation

public enum RouteFileLoadError: Error, LocalizedError, Equatable {
    case unsupportedFileType(String)
    case unreadableFile
    case parseFailed(String)
    case noTrackpoints

    public var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let ext):
            return "지원하지 않는 파일 형식입니다: \(ext)"
        case .unreadableFile:
            return "파일을 읽을 수 없습니다."
        case .parseFailed(let message):
            return message
        case .noTrackpoints:
            return "파일에 표시할 경로 포인트가 없습니다."
        }
    }
}

public enum RouteFileLoader {
    public static let supportedFilenameExtensions = ["gpx", "tcx", "csb"]

    public static func load(from url: URL) throws -> LoadedCourse {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw RouteFileLoadError.unreadableFile
        }
        return try load(data: data, filename: url.lastPathComponent, sourceURL: url)
    }

    public static func load(
        data: Data,
        filename: String,
        sourceURL: URL? = nil
    ) throws -> LoadedCourse {
        let filenameURL = URL(fileURLWithPath: filename)
        let ext = filenameURL.pathExtension.lowercased()
        let fallbackTitle = filenameURL.deletingPathExtension().lastPathComponent
        let resolvedURL = sourceURL ?? filenameURL

        switch ext {
        case "tcx":
            return try TCXRouteParser(
                data: data,
                sourceURL: resolvedURL,
                fallbackTitle: fallbackTitle
            ).course()
        case "gpx":
            return try GPXRouteParser(
                data: data,
                sourceURL: resolvedURL,
                fallbackTitle: fallbackTitle
            ).course()
        case "csb":
            return try CSBRouteParser(
                data: data,
                sourceURL: resolvedURL,
                fallbackTitle: fallbackTitle
            ).course()
        default:
            throw RouteFileLoadError.unsupportedFileType(ext)
        }
    }

    static func normalizedTitle(_ title: String?, fallback: String) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        let fallbackTrimmed = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackTrimmed.isEmpty ? "Course" : fallbackTrimmed
    }

    static func cuePoints(
        from rawCuePoints: [RawCuePoint],
        trackPoints: [TrackPoint]
    ) -> [CourseCuePoint] {
        rawCuePoints.map { point in
            let nearestByTime = point.time.flatMap { time in
                trackPoints.firstIndex(where: { $0.time == time })
            }
            let nearest = nearestByTime
                ?? Geo.nearestIndex(trackPoints, lat: point.lat, lon: point.lon)
            let distanceMeters = point.distanceMeters
                ?? nearest.map { trackPoints[$0].cumKm * 1_000 }
                ?? 0
            return CourseCuePoint(
                lat: point.lat,
                lon: point.lon,
                name: point.name,
                pointType: point.pointType,
                notes: point.notes,
                distanceMeters: distanceMeters
            )
        }
        .sorted { $0.distanceMeters < $1.distanceMeters }
    }
}

struct RawCuePoint: Equatable {
    var lat: Double
    var lon: Double
    var time: String?
    var name: String
    var pointType: String
    var notes: String
    var distanceMeters: Double?

    init(
        lat: Double,
        lon: Double,
        time: String? = nil,
        name: String,
        pointType: String,
        notes: String,
        distanceMeters: Double? = nil
    ) {
        self.lat = lat
        self.lon = lon
        self.time = time
        self.name = name
        self.pointType = pointType
        self.notes = notes
        self.distanceMeters = distanceMeters
    }
}
