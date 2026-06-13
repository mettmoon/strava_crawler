import SwiftUI

struct RouteCommands: Commands {
    @FocusedValue(\.routeCommandHandler) private var handler
    @FocusedValue(\.addRouteAction) private var addRoute
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("경로") {
            Button("경로에서 코스 만들기…") {
                openWindow(id: "route-library")
            }

            Divider()

            Button("경로 추가…") {
                addRoute?()
            }
            .disabled(addRoute == nil)
            .keyboardShortcut("N", modifiers: [.command])

            Divider()

            Button("TCX 내보내기…") {
                handler?.export()
            }
            .disabled(handler == nil || handler?.canExport == false)
            .keyboardShortcut("E", modifiers: [.command, .shift])

            Divider()

            Button("코스 만들기") {
                handler?.makeIntoCourse()
            }
            .disabled(handler == nil || handler?.canExport == false)

            Divider()

            Button("다시 불러오기") {
                handler?.redownload()
            }
            .disabled(handler == nil)
            .keyboardShortcut("R", modifiers: [.command, .option])

            Button("삭제") {
                handler?.delete()
            }
            .disabled(handler == nil)
        }
    }
}
