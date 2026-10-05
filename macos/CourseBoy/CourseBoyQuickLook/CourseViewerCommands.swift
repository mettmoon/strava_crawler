import SwiftUI

extension FocusedValues {
    @Entry var courseViewerCommandHandler: CourseViewerCommandHandler? = nil
}

/// Commands 블록에서 뷰어 상태에 접근할 수 없으므로, 열린 코스 뷰어가 액션 클로저를 묶어 FocusedValue로 주입한다.
struct CourseViewerCommandHandler {
    var selectPreviousCue: () -> Void
    var selectNextCue: () -> Void
    var clearSelection: () -> Void
    var fitCourse: () -> Void
    var toggleLocation: () -> Void
    var toggleElevationChart: () -> Void
    var hasCues: Bool
    var hasSelection: Bool
    var showsElevationChart: Bool
}

/// iPad 하드웨어 키보드 단축키. ⌘를 길게 누르면 나오는 목록과 메뉴 막대에도 표시된다.
struct CourseViewerCommands: Commands {
    @FocusedValue(\.courseViewerCommandHandler) private var handler

    var body: some Commands {
        CommandMenu("코스") {
            Button("이전 큐") {
                handler?.selectPreviousCue()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(handler?.hasCues != true)

            Button("다음 큐") {
                handler?.selectNextCue()
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(handler?.hasCues != true)

            Button("선택 해제") {
                handler?.clearSelection()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(handler?.hasSelection != true)

            Divider()

            Button("코스 전체 보기") {
                handler?.fitCourse()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(handler == nil)

            Button("내 위치") {
                handler?.toggleLocation()
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(handler == nil)

            Button(handler?.showsElevationChart == false ? "고도 그래프 보기" : "고도 그래프 숨기기") {
                handler?.toggleElevationChart()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(handler == nil)
        }
    }
}
