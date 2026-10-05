import SwiftUI

@main
struct CourseBoyQuickLookApp: App {
    var body: some Scene {
        // 창마다 FilePreviewHomeView가 열린 코스를 따로 들고 있어 iPad에서 여러 코스를 나란히 띄울 수 있다.
        WindowGroup {
            FilePreviewHomeView()
        }
        .commands {
            CourseViewerCommands()
        }
    }
}
