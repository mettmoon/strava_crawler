import SwiftUI
import SwiftData

@main
struct StravaTCXApp: App {
    @State private var container = try! AppContainer()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environment(container.makeRouteListViewModel())
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 680)
        .windowResizability(.contentMinSize)
        .modelContainer(container.modelContainer)
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
        .modelContainer(container.modelContainer)

        WindowGroup("구간 목록", id: "segment-library") {
            SegmentLibraryView(vm: container.makeSegmentLibraryViewModel())
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 460, height: 640)
        .windowResizability(.contentMinSize)

        WindowGroup("구간 상세", id: "segment-workspace", for: String.self) { $segmentID in
            SegmentWorkspaceView(segmentID: segmentID, container: container)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 680)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }
    }
}
