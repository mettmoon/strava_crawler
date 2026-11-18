import SwiftUI
import SwiftData

@main
struct CourseBoyApp: App {
    @NSApplicationDelegateAdaptor(CourseBoyAppDelegate.self) private var appDelegate
    @State private var container: AppContainer
    @State private var routeListVM: RouteListViewModel

    init() {
        // 정상 종료(⌘Q) 뒤에도 열려 있던 문서 창을 다음 실행 때 복원한다. 기본값으로만 등록하므로
        // 사용자가 시스템 설정에서 "응용 프로그램을 종료할 때 윈도우 닫기"를 직접 정했다면 그 값을 따른다.
        UserDefaults.standard.register(defaults: [QuitRestoration.keepsWindowsDefaultsKey: true])

        let c = try! AppContainer()
        _container = State(initialValue: c)
        _routeListVM = State(initialValue: c.makeRouteListViewModel())
    }

    var body: some Scene {
        DocumentGroup(newDocument: { CourseDocument() }) { configuration in
            CourseDocumentView(
                document: configuration.document,
                container: container,
                fileURL: configuration.fileURL
            )
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1100, height: 680)
        .windowResizability(.contentMinSize)

        WindowGroup("코스로 만들 경로", id: "route-library") {
            RouteLibraryView()
                .environment(routeListVM)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 540, height: 660)
        .windowResizability(.contentMinSize)
        .modelContainer(container.modelContainer)

        WindowGroup("코스 만들기", id: "route-workspace", for: String.self) { $routeID in
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

        WindowGroup("Welcome to CourseBoy", id: "welcome") {
            WelcomeView()
                .environment(routeListVM)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 940, height: 600)
        .windowResizability(.contentMinSize)
        .modelContainer(container.modelContainer)
        .defaultLaunchBehavior(.presented)
        .commands { CourseFileCommands() }
        .commands { RouteCommands() }
        .commands { CourseCommands() }
        .commands { WelcomeWindowCommands() }
        .commands { QuitCommands() }

        Settings {
            SettingsView()
        }
    }
}

private struct WelcomeWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Welcome to CourseBoy") {
                openWindow(id: "welcome")
            }
            .keyboardShortcut("1", modifiers: [.command, .shift])
        }
    }
}

/// TCX·GPX 로 열어 원본과 끊어 둔 문서는 변경 표시가 없어서, 그대로 종료하면 자동저장본이 지워져
/// 다음 실행 때 복원되지 않는다. 창을 복원하는 종료라면 종료 전에 변경된 문서로 표시해 자동저장본이
/// 남게 한다. 종료 절차가 시작된 뒤에는 문서가 이미 닫혀 있어 늦으므로, 종료 메뉴(⌘Q)와
/// 종료 요청(Dock 의 종료 등)을 받는 자리에서 먼저 처리한다.
enum QuitRestoration {
    static let keepsWindowsDefaultsKey = "NSQuitAlwaysKeepsWindows"

    @MainActor
    static func quit() {
        keepDetachedDocumentsForRestoration()
        NSApp.terminate(nil)
    }

    @MainActor
    private static func keepDetachedDocumentsForRestoration() {
        guard UserDefaults.standard.bool(forKey: keepsWindowsDefaultsKey) else { return }

        for document in NSDocumentController.shared.documents
        where document.fileURL == nil && document.autosavedContentsFileURL != nil && !document.isDocumentEdited {
            document.updateChangeCount(.changeDone)
        }
    }
}

final class CourseBoyAppDelegate: NSObject, NSApplicationDelegate {
    /// Dock 의 종료처럼 밖에서 오는 종료 요청은 메뉴를 거치지 않으므로 여기서 받아 같은 처리를 한다.
    /// AppKit 이 기본 처리기를 등록한 뒤에 바꿔야 해서 실행이 끝난 시점에 등록한다.
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )
    }

    @MainActor @objc private func handleQuitEvent(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        QuitRestoration.quit()
    }
}

private struct QuitCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appTermination) {
            Button("Quit CourseBoy") {
                QuitRestoration.quit()
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
