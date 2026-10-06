import SwiftUI

@main
struct CourseBoyQuickLookApp: App {
    var body: some Scene {
        // 창마다 홈 화면과 열린 코스를 따로 두어 iPad에서 여러 코스를 나란히 띄울 수 있다.
        WindowGroup {
            CourseHomeView()
        }
        .commands {
            CourseViewerCommands()
        }
    }
}
