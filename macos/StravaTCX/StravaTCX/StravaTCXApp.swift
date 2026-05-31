import SwiftUI
import SwiftData

@main
struct StravaTCXApp: App {
    var body: some Scene {
        WindowGroup {
            RouteListView()
                .frame(minWidth: 820, minHeight: 560)
        }
        .windowResizability(.contentMinSize)
        .modelContainer(for: RouteRecord.self)

        Settings {
            SettingsView()
        }
    }
}
