import SwiftUI

struct SegmentCommands: Commands {
    @FocusedValue(\.selectedSegment) private var selectedSegment
    @FocusedValue(\.segmentCommandHandler) private var handler

    var body: some Commands {
        CommandMenu("구간") {
            Button("다시 불러오기") {
                guard let h = handler else { return }
                Task { await h.reload() }
            }
            .disabled(selectedSegment == nil)
            .keyboardShortcut("R", modifiers: [.command, .shift])

            Divider()

            Button("삭제하기") {
                handler?.delete()
            }
            .disabled(selectedSegment == nil)
        }
    }
}
