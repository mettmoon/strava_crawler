import SwiftUI
import SwiftData
import StravaTCXKit

extension FocusedValues {
    @Entry var selectedSegment: SegmentInfo? = nil
    @Entry var segmentCommandHandler: SegmentCommandHandler? = nil
    @Entry var routeCommandHandler: RouteCommandHandler? = nil
    @Entry var courseCommandHandler: CourseCommandHandler? = nil
}

/// Commands 블록에서 modelContext·coordinator 에 접근할 수 없으므로,
/// MainTabView 가 액션 클로저를 묶어서 FocusedValue 로 주입한다.
struct SegmentCommandHandler {
    var reload: () async -> Void
    var delete: () -> Void
}

struct RouteCommandHandler {
    var export: () -> Void
    var redownload: () -> Void
    var delete: () -> Void
    var makeIntoCourse: () -> Void
    var canExport: Bool
}

struct CourseCommandHandler {
    var exportTCX: () -> Void
    var delete: () -> Void
}
