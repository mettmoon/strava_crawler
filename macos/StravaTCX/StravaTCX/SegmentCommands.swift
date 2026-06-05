import SwiftUI

struct SegmentCommands: Commands {
    @FocusedValue(\.selectedSegment) private var selectedSegment
    @FocusedValue(\.segmentCommandHandler) private var handler
    @FocusedValue(\.addRouteAction) private var addRoute

    var body: some Commands {
        CommandMenu("구간") {
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
            .disabled(selectedSegment == nil)
            .keyboardShortcut("R", modifiers: [.command, .shift])

            Divider()

            Button("삭제하기") {
                guard let h = handler else { return }
                Task { try? await h.delete() }
            }
            .disabled(selectedSegment == nil)
        }
    }
}
