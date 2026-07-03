import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let coursePlan = UTType(exportedAs: "com.peter.courseboy.course-plan", conformingTo: .xml)
    static var coursePlanFileExtension: UTType {
        UTType(filenameExtension: "csb", conformingTo: .xml) ?? .coursePlan
    }
}

final class CourseDocument: ReferenceFileDocument, @unchecked Sendable {
    typealias Snapshot = Data

    static let readableFilenameExtensions = ["csb", "tcx", "gpx"]
    static let coursePlanFilenameExtensions = ["csb"]

    static var readableContentTypes: [UTType] {
        [.coursePlan, .coursePlanFileExtension, .tcx, .gpx, .xmlGPX]
    }
    static var writableContentTypes: [UTType] { [.coursePlan] }

    static func normalizedReadableFileURL(_ url: URL) -> URL? {
        normalizedFileURL(url, allowedExtensions: readableFilenameExtensions)
    }

    static func normalizedCoursePlanFileURL(_ url: URL) -> URL? {
        normalizedFileURL(url, allowedExtensions: coursePlanFilenameExtensions)
    }

    private static func normalizedFileURL(_ url: URL, allowedExtensions: [String]) -> URL? {
        let fileURL: URL
        if (url as NSURL).isFileReferenceURL(), let resolvedURL = (url as NSURL).filePathURL {
            fileURL = resolvedURL
        } else {
            fileURL = url
        }

        guard fileURL.isFileURL else { return nil }
        guard allowedExtensions.contains(fileURL.pathExtension.lowercased()) else { return nil }

        return fileURL.standardizedFileURL
    }

    @Published var course: CourseRecord {
        didSet { observeCourse() }
    }

    private var courseCancellable: AnyCancellable?

    init(course: CourseRecord = CourseRecord(title: "새 코스")) {
        self.course = course
        observeCourse()
    }

    required init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let filename = configuration.file.preferredFilename ?? configuration.file.filename ?? ""
        let fallbackTitle = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension.lowercased()
        let contentType = configuration.contentType

        if ext == "tcx" || contentType.conforms(to: .tcx) {
            course = try CourseTCXFileCoder.makeRecord(from: data, fallbackTitle: fallbackTitle, sourceFilePath: nil)
        } else if ext == "gpx" || contentType.conforms(to: .gpx) || contentType.conforms(to: .xmlGPX) {
            course = try CourseGPXFileCoder.makeRecord(from: data, fallbackTitle: fallbackTitle, sourceFilePath: nil)
        } else {
            course = try CoursePlanFileCoder.makeRecord(from: data)
        }

        observeCourse()
    }

    func snapshot(contentType: UTType) throws -> Data {
        try CoursePlanFileCoder.data(from: course)
    }

    func fileWrapper(snapshot: Data, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: snapshot)
    }

    private func observeCourse() {
        courseCancellable = course.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}
