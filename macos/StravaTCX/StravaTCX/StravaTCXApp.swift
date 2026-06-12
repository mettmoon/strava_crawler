import SwiftUI
import SwiftData

@main
struct StravaTCXApp: App {
    @State private var container: AppContainer
    @State private var routeListVM: RouteListViewModel

    init() {
        let c = try! AppContainer()
        _container = State(initialValue: c)
        _routeListVM = State(initialValue: c.makeRouteListViewModel())
    }

    var body: some Scene {
        WindowGroup {
            WelcomeView()
                .environment(routeListVM)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 720, height: 600)
        .windowResizability(.contentMinSize)
        .modelContainer(container.modelContainer)
        .commands { SegmentCommands() }
        .commands { RouteCommands() }
        .commands { CourseCommands() }

        WindowGroup("경로 목록", id: "route-library") {
            RouteLibraryView()
                .environment(routeListVM)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 460, height: 640)
        .windowResizability(.contentMinSize)
        .modelContainer(container.modelContainer)

        WindowGroup("경로 상세", id: "route-workspace", for: String.self) { $routeID in
            RouteWorkspaceView(routeID: routeID, container: container)
                .environment(routeListVM)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 680)
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

        WindowGroup("코스 목록", id: "course-library") {
            CourseLibraryView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 460, height: 640)
        .windowResizability(.contentMinSize)
        .modelContainer(container.modelContainer)

        WindowGroup("코스 상세", id: "course-workspace", for: UUID.self) { $courseID in
            CourseWorkspaceView(courseID: courseID, container: container)
                .environment(routeListVM)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 680)
        .windowResizability(.contentMinSize)
        .modelContainer(container.modelContainer)

        WindowGroup("코스 편집", id: "course-editor", for: UUID.self) { $courseID in
            CourseEditorWindowView(courseID: courseID)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1400, height: 860)
        .windowResizability(.contentMinSize)
        .modelContainer(container.modelContainer)

        WindowGroup("경로 3D", id: "route-3d", for: String.self) { $routeID in
            Route3DWindowView(routeID: routeID, container: container)
                .environment(routeListVM)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 960, height: 640)
        .windowResizability(.contentMinSize)
        .modelContainer(container.modelContainer)

        WindowGroup("구간 3D", id: "segment-3d", for: String.self) { $segmentID in
            Segment3DWindowView(segmentID: segmentID, container: container)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 960, height: 640)
        .windowResizability(.contentMinSize)

        WindowGroup("코스 3D", id: "course-3d", for: UUID.self) { $courseID in
            Course3DWindowView(courseID: courseID, container: container)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 960, height: 640)
        .windowResizability(.contentMinSize)
        .modelContainer(container.modelContainer)

        Settings {
            SettingsView()
        }
    }
}
