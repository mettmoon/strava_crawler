import SwiftUI

struct CourseCommands: Commands {
    @FocusedValue(\.courseCommandHandler) private var handler

    var body: some Commands {
        CommandMenu("코스") {
            Button("편집…") {
                handler?.edit()
            }
            .disabled(handler == nil)
            .keyboardShortcut("E", modifiers: [.command])

            Divider()

            Button("구간정보 복사하기") {
                handler?.copySegmentInfo()
            }
            .disabled(handler?.canCopySegmentInfo != true)
        }
    }
}
