import CoursePreviewCore
import SwiftUI
import UniformTypeIdentifiers

/// DocumentGroup이 여는 GPX·TCX 파일. 보기 전용이라 저장은 지원하지 않는다.
struct CourseFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.courseBoyGPX, .courseBoyTCX] }
    static var writableContentTypes: [UTType] { [] }

    let course: LoadedCourse

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw RouteFileLoadError.unreadableFile
        }
        // 형식은 확장자로 고르므로 파일 이름이 없으면 콘텐츠 형식에 맞는 확장자를 붙인다.
        let fallbackName = configuration.contentType == .courseBoyGPX ? "course.gpx" : "course.tcx"
        course = try RouteFileLoader.load(data: data, filename: configuration.file.filename ?? fallbackName)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        throw CocoaError(.fileWriteNoPermission)
    }
}

extension UTType {
    static let courseBoyGPX = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
    static let courseBoyTCX = UTType(importedAs: "com.garmin.tcx", conformingTo: .xml)
}
