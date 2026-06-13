import Foundation
import UniformTypeIdentifiers

enum CourseImportFileError: Error, LocalizedError {
    case unsupportedFileType(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType(let ext):
            return "지원하지 않는 파일 형식입니다: \(ext)"
        }
    }
}

extension UTType {
    static var gpx: UTType { UTType(filenameExtension: "gpx") ?? .xml }
    static var xmlGPX: UTType { UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .gpx }
}

enum CourseImportFileCoder {
    static var readableContentTypes: [UTType] { [.tcx, .gpx, .xmlGPX] }

    static func makeRecord(from url: URL) throws -> CourseRecord {
        let data = try Data(contentsOf: url)
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        let sourceFilePath = url.path

        switch url.pathExtension.lowercased() {
        case "tcx":
            return try CourseTCXFileCoder.makeRecord(
                from: data,
                fallbackTitle: fallbackTitle,
                sourceFilePath: sourceFilePath
            )
        case "gpx":
            return try CourseGPXFileCoder.makeRecord(
                from: data,
                fallbackTitle: fallbackTitle,
                sourceFilePath: sourceFilePath
            )
        default:
            throw CourseImportFileError.unsupportedFileType(url.pathExtension)
        }
    }
}
