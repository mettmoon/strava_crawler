import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CourseFileCommands: Commands {
    @Environment(\.newDocument) private var newDocument
    @FocusedValue(\.courseFileCommandHandler) private var handler

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button("Import from TCX/GPX...") {
                importCourseFile()
            }

            Button("Export to TCX...") {
                handler?.exportTCX()
            }
            .disabled(handler == nil || handler?.canExportTCX == false)
        }
    }

    @MainActor
    private func importCourseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = CourseImportFileCoder.readableContentTypes
        panel.prompt = "Import"
        panel.message = "Import a TCX or GPX course file"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let course = try CourseImportFileCoder.makeRecord(from: url)
            let document = CourseDocument(course: course)
            newDocument { document }
        } catch {
            showError("TCX/GPX 파일을 불러올 수 없습니다.", detail: error.localizedDescription)
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
