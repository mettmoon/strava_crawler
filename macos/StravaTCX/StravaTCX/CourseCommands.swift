import SwiftUI

struct CourseCommands: Commands {
    @FocusedValue(\.courseCommandHandler) private var handler
    @FocusedValue(\.createCourseAction) private var createCourse
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("코스") {
            Button("코스 불러오기…") {
                openWindow(id: "course-library")
            }
            .keyboardShortcut("3", modifiers: [.command, .shift])

            Divider()

            Button("새 코스") {
                createCourse?()
            }
            .disabled(createCourse == nil)
            .keyboardShortcut("N", modifiers: [.command, .shift])

            Divider()

            Button("편집…") {
                handler?.edit()
            }
            .disabled(handler == nil)
            .keyboardShortcut("E", modifiers: [.command])

            Divider()

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
