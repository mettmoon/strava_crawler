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
        .modelContainer(for: RouteRecord.self)

        Settings {
            SettingsView()
        }
    }
}
