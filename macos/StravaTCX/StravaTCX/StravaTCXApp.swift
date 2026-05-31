import SwiftUI
import SwiftData

@main
struct StravaTCXApp: App {
    @State private var coordinator = ImportCoordinator()

    var body: some Scene {
        WindowGroup {
            RouteListView()
                .environment(coordinator)
                .frame(minWidth: 820, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .modelContainer(for: RouteRecord.self)

        Settings {
            SettingsView()
        }
    }
}
