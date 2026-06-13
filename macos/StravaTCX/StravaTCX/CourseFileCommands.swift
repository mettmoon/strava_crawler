import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct CourseFileCommands: Commands {
    var container: AppContainer

    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.courseFileCommandHandler) private var handler

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Menu("New") {
                Button("코스") {
                    createCourse()
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        CommandGroup(after: .newItem) {
            Button("열기...") {
                openTCX()
            }
            .keyboardShortcut("o", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("저장") {
                handler?.saveTCX()
            }
            .disabled(handler == nil || handler?.canSaveTCX == false)
            .keyboardShortcut("s", modifiers: .command)
        }
    }

    @MainActor
    private func createCourse() {
        let context = container.modelContainer.mainContext
        let count = (try? context.fetch(FetchDescriptor<CourseRecord>()).count) ?? 0
        let course = CourseRecord(title: "새 코스 \(count + 1)")
        context.insert(course)

        do {
            try context.save()
            openWindow(id: "course-editor", value: course.id)
        } catch {
            context.rollback()
            showError("코스를 만들 수 없습니다.", detail: error.localizedDescription)
        }
    }

    @MainActor
    private func openTCX() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.tcx]
        panel.prompt = "열기"
        panel.message = "열 TCX 코스 파일을 선택하세요"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let data = try Data(contentsOf: url)
            let title = url.deletingPathExtension().lastPathComponent
            let course = try CourseTCXFileCoder.makeRecord(
                from: data,
                fallbackTitle: title,
                sourceFilePath: url.path
            )
            let context = container.modelContainer.mainContext
            context.insert(course)
            try context.save()
            openWindow(id: "course-workspace", value: course.id)
        } catch {
            showError("TCX 파일을 열 수 없습니다.", detail: error.localizedDescription)
        }
    }

    @MainActor
    private func showError(_ message: String, detail: String) {
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }
}
