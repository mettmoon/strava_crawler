import CoursePreviewCore
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let courseBoyGPX = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
    static let courseBoyTCX = UTType(importedAs: "com.garmin.tcx", conformingTo: .xml)

    /// 홈 화면 파일 선택기와 드롭이 받는 코스 파일 형식.
    static let courseBoyReadable: [UTType] = [.courseBoyGPX, .courseBoyTCX]
}

/// 코스 파일을 읽어 파싱한 결과. 최근 목록은 원본 바이트로 중복 여부를 가린다.
struct ReadCourseFile: Sendable {
    var course: LoadedCourse
    var data: Data
}

enum CourseFileReader {
    /// 보안 범위 URL을 열고 NSFileCoordinator로 읽는다. 아직 내려받지 않은 iCloud 파일도 읽기 전에 내려받는다.
    /// 파일 읽기와 파싱이 무거울 수 있어 메인 스레드 밖에서 돌린다.
    static func read(_ url: URL) async throws -> ReadCourseFile {
        try await Task.detached(priority: .userInitiated) {
            try readSynchronously(url)
        }.value
    }

    static func readSynchronously(_ url: URL) throws -> ReadCourseFile {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(RouteFileLoadError.unreadableFile)
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try Data(contentsOf: readURL, options: [.mappedIfSafe]) }
        }
        if coordinationError != nil {
            throw RouteFileLoadError.unreadableFile
        }
        guard let data = try? result.get() else {
            throw RouteFileLoadError.unreadableFile
        }
        let course = try RouteFileLoader.load(data: data, filename: url.lastPathComponent, sourceURL: url)
        return ReadCourseFile(course: course, data: data)
    }
}
