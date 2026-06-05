import SwiftUI

struct RouteCommands: Commands {
    @FocusedValue(\.routeCommandHandler) private var handler

    var body: some Commands {
        CommandMenu("경로") {
            Button("TCX 내보내기…") {
                handler?.export()
            }
            .disabled(handler == nil || handler?.canExport == false)
            .keyboardShortcut("E", modifiers: [.command, .shift])

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
