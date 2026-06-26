import Foundation

enum RouteFileLoadError: Error, LocalizedError {
    case unsupportedFileType(String)
    case unreadableFile
    case parseFailed(String)
    case noTrackpoints

    var errorDescription: String? {
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

enum RouteFileLoader {
    static func load(from url: URL) throws -> LoadedCourse {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = try? Data(contentsOf: url) else {
            throw RouteFileLoadError.unreadableFile
        }

        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        switch url.pathExtension.lowercased() {
        case "tcx":
            return try TCXRouteParser(data: data, sourceURL: url, fallbackTitle: fallbackTitle).course()
        case "gpx":
            return try GPXRouteParser(data: data, sourceURL: url, fallbackTitle: fallbackTitle).course()
        default:
            throw RouteFileLoadError.unsupportedFileType(url.pathExtension)
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
            let nearest = Geo.nearestIndex(trackPoints, lat: point.lat, lon: point.lon)
            let distanceMeters = nearest.map { trackPoints[$0].cumKm * 1000 } ?? 0
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
    var name: String
    var pointType: String
    var notes: String
}
