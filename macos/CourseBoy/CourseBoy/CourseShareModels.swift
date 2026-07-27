import AppKit
import Foundation
import SwiftUI
import CourseBoyKit

enum CourseShareOutputMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case combined
    case mapOnly
    case elevationOnly
    case separate

    var id: String { rawValue }

    var label: String {
        switch self {
        case .combined: return "코스 + 고도표 한 장"
        case .mapOnly: return "코스만"
        case .elevationOnly: return "고도표만"
        case .separate: return "코스 + 고도표 각각"
        }
    }

    var includesMap: Bool {
        self != .elevationOnly
    }

    var includesElevation: Bool {
        self != .mapOnly
    }
}

enum CourseShareMapBackground: String, CaseIterable, Identifiable, Codable, Sendable {
    case appleLight
    case appleDark
    case openStreetMap
    case solid

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appleLight: return "Apple 지도 (라이트)"
        case .appleDark: return "Apple 지도 (다크)"
        case .openStreetMap: return "OpenStreetMap"
        case .solid: return "끔 (배경색)"
        }
    }
}

struct CourseShareColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let warmGray = CourseShareColor(
        red: 0.945,
        green: 0.94,
        blue: 0.925,
        alpha: 1
    )

    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    var nsColor: NSColor {
        NSColor(
            calibratedRed: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(color: Color) {
        let converted = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
        red = Double(converted.redComponent)
        green = Double(converted.greenComponent)
        blue = Double(converted.blueComponent)
        alpha = Double(converted.alphaComponent)
    }
}

struct CourseSharePixelSize: Codable, Equatable, Sendable {
    var width: Int
    var height: Int

    static let defaultMap = CourseSharePixelSize(width: 1080, height: 1080)
    static let defaultElevation = CourseSharePixelSize(width: 1080, height: 405)

    static let mapPresets: [(label: String, size: CourseSharePixelSize)] = [
        ("정사각형", CourseSharePixelSize(width: 1080, height: 1080)),
        ("세로형", CourseSharePixelSize(width: 1080, height: 1350)),
        ("가로형", CourseSharePixelSize(width: 1920, height: 1080)),
    ]

    static let elevationPresets: [(label: String, size: CourseSharePixelSize)] = [
        ("기본", CourseSharePixelSize(width: 1080, height: 405)),
        ("넓게", CourseSharePixelSize(width: 1600, height: 600)),
        ("Full HD 폭", CourseSharePixelSize(width: 1920, height: 640)),
    ]

    var isValid: Bool {
        width >= 320
            && height >= 240
            && width <= 8192
            && height <= 8192
            && width * height <= 32_000_000
    }

    func scaledToFit(maxDimension: Int) -> CourseSharePixelSize {
        let longest = max(width, height)
        guard longest > maxDimension else { return self }
        let scale = Double(maxDimension) / Double(longest)
        return CourseSharePixelSize(
            width: max(1, Int((Double(width) * scale).rounded())),
            height: max(1, Int((Double(height) * scale).rounded()))
        )
    }
}

struct CourseShareOptions: Codable, Equatable, Sendable {
    var outputMode: CourseShareOutputMode = .combined
    var mapBackground: CourseShareMapBackground = .appleLight
    var solidBackgroundColor: CourseShareColor = .warmGray
    var routeLineWidth: Double = 6
    var showsMapEndpoints: Bool = true
    var showsMapWaypoints: Bool = true
    var usesDarkElevationStyle: Bool = false
    var showsElevationWaypoints: Bool = true
    var mapSize: CourseSharePixelSize = .defaultMap
    var elevationSize: CourseSharePixelSize = .defaultElevation

    var effectiveElevationSize: CourseSharePixelSize {
        guard outputMode == .combined else { return elevationSize }
        return CourseSharePixelSize(width: mapSize.width, height: elevationSize.height)
    }

    var isValid: Bool {
        let componentSizesAreValid = (!outputMode.includesMap || mapSize.isValid)
            && (!outputMode.includesElevation || effectiveElevationSize.isValid)
            && routeLineWidth >= 1
            && routeLineWidth <= 24
        guard componentSizesAreValid else { return false }
        guard outputMode == .combined else { return true }
        return CourseSharePixelSize(
            width: mapSize.width,
            height: mapSize.height + effectiveElevationSize.height
        ).isValid
    }

    func previewScaled(maxDimension: Int = 1200) -> CourseShareOptions {
        var copy = self
        copy.mapSize = mapSize.scaledToFit(maxDimension: maxDimension)
        copy.elevationSize = effectiveElevationSize.scaledToFit(maxDimension: maxDimension)
        if mapSize.width > 0 {
            copy.routeLineWidth = max(
                1,
                routeLineWidth * Double(copy.mapSize.width) / Double(mapSize.width)
            )
        }
        if outputMode == .combined {
            copy.elevationSize.width = copy.mapSize.width
        }
        return copy
    }
}

struct CourseShareSnapshot: Sendable {
    let title: String
    let sectionTrackPoints: [[TrackPoint]]
    let cuePoints: [CourseCuePoint]

    @MainActor
    init(course: CourseRecord) {
        let trimmedTitle = course.title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = trimmedTitle.isEmpty ? "Course" : trimmedTitle
        sectionTrackPoints = course.adjustedSectionTrackPoints.filter { !$0.isEmpty }
        cuePoints = course.cuePoints
    }

    var allTrackPoints: [TrackPoint] {
        sectionTrackPoints.flatMap { $0 }
    }

    var hasRoute: Bool {
        sectionTrackPoints.contains { $0.count >= 2 }
    }

    var hasElevation: Bool {
        allTrackPoints.lazy.compactMap(\.ele).prefix(2).count >= 2
    }
}

enum CourseShareArtifactKind: String, Sendable {
    case combined
    case map
    case elevation

    var filenameSuffix: String {
        switch self {
        case .combined: return ""
        case .map: return "-map"
        case .elevation: return "-elevation"
        }
    }
}

struct CourseShareArtifact {
    let kind: CourseShareArtifactKind
    let image: NSImage
}

struct CourseShareRenderResult {
    let artifacts: [CourseShareArtifact]
    let previewImage: NSImage
}

enum CourseShareError: LocalizedError {
    case noRoute
    case noElevation
    case invalidImageSize
    case mapSnapshotFailed
    case tileDownloadFailed
    case imageEncodingFailed
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRoute:
            return "공유할 코스 경로가 없습니다."
        case .noElevation:
            return "고도표를 만들 수 있는 고도 데이터가 부족합니다."
        case .invalidImageSize:
            return "이미지 크기는 320×240 이상, 각 변 8192px 이하, 총 3,200만 픽셀 이하여야 합니다."
        case .mapSnapshotFailed:
            return "Apple 지도 이미지를 불러오지 못했습니다."
        case .tileDownloadFailed:
            return "OpenStreetMap 타일을 모두 불러오지 못했습니다."
        case .imageEncodingFailed:
            return "PNG 이미지를 만들지 못했습니다."
        case .saveFailed(let detail):
            return "이미지를 저장하지 못했습니다. \(detail)"
        }
    }
}
