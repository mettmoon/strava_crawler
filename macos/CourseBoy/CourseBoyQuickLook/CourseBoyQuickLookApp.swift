import SwiftUI

@main
struct CourseBoyQuickLookApp: App {
    var body: some Scene {
        // 창마다 문서 브라우저와 열린 코스를 따로 두어 iPad에서 여러 코스를 나란히 띄울 수 있다.
        DocumentGroup(viewing: CourseFileDocument.self) { file in
            CourseDocumentWindowView(course: file.document.course)
        }
        .commands {
            CourseViewerCommands()
        }
    }
}
