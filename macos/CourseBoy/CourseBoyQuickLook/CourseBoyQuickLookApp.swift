import SwiftUI

@main
struct CourseBoyQuickLookApp: App {
    @State private var loadedCourse: LoadedCourse?

    var body: some Scene {
        WindowGroup {
            FilePreviewHomeView(loadedCourse: $loadedCourse)
        }
    }
}
