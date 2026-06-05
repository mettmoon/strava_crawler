import SwiftUI

struct CourseCommands: Commands {
    @FocusedValue(\.courseCommandHandler) private var handler

    var body: some Commands {
        CommandMenu("코스") {
            Button("TCX 내보내기…") {
                handler?.exportTCX()
            }
            .disabled(handler == nil)
            .keyboardShortcut("E", modifiers: [.command, .shift, .option])

            Divider()

            Button("삭제") {
                handler?.delete()
            }
            .disabled(handler == nil)
        }
    }
}
