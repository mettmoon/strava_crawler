import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let coursePlan = UTType(exportedAs: "com.peter.courseboy.course-plan", conformingTo: .xml)
    static let legacyCoursePlan = UTType(importedAs: "com.peter.stravatcx.course-plan", conformingTo: .xml)
    static var coursePlanFileExtension: UTType {
        UTType(filenameExtension: "cpn", conformingTo: .xml) ?? .coursePlan
    }
}

final class CourseDocument: ReferenceFileDocument, @unchecked Sendable {
    typealias Snapshot = Data

    static var readableContentTypes: [UTType] { [.coursePlan, .legacyCoursePlan, .coursePlanFileExtension] }
    static var writableContentTypes: [UTType] { [.coursePlan] }

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
        course = try CoursePlanFileCoder.makeRecord(from: data)
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
