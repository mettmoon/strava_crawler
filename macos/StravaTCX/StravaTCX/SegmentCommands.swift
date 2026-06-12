import SwiftUI

struct SegmentCommands: Commands {
    @FocusedValue(\.addRouteAction) private var addRoute
    @FocusedValue(\.segmentCommandHandler) private var handler
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("구간") {
            Button("구간 목록 보기") {
                openWindow(id: "segment-library")
            }
            .keyboardShortcut("2", modifiers: [.command, .shift])

            Divider()

            Button("경로 추가…") {
                addRoute?()
            }
            .disabled(addRoute == nil)
            .keyboardShortcut("N", modifiers: [.command, .shift, .option])

            Divider()

            Button("다시 불러오기") {
                guard let h = handler else { return }
                Task { try await h.reload() }
            }
            .disabled(handler == nil)
            .keyboardShortcut("R", modifiers: [.command, .shift])

            Button("삭제하기") {
                guard let h = handler else { return }
                Task { try? await h.delete() }
            }
            .disabled(handler == nil)
        }
    }
}
