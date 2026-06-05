import SwiftUI
import SwiftData

@main
struct StravaTCXApp: App {
    @State private var coordinator = ImportCoordinator()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(coordinator)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 680)
        .windowResizability(.contentMinSize)
        .modelContainer(for: [RouteRecord.self, CourseRecord.self])
        .commands { SegmentCommands() }
        .commands { RouteCommands() }
        .commands { CourseCommands() }

        WindowGroup("코스 편집", id: "course-editor", for: UUID.self) { $courseID in
            CourseEditorWindowView(courseID: courseID)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1400, height: 860)
        .windowResizability(.contentMinSize)
        .modelContainer(for: [RouteRecord.self, CourseRecord.self])

        Settings {
            SettingsView()
        }
    }
}
