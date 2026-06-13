import SwiftUI
import SwiftData
import StravaTCXKit

extension FocusedValues {
    @Entry var segmentCommandHandler: SegmentCommandHandler? = nil
    @Entry var routeCommandHandler: RouteCommandHandler? = nil
    @Entry var courseCommandHandler: CourseCommandHandler? = nil
    @Entry var courseFileCommandHandler: CourseFileCommandHandler? = nil
    @Entry var createCourseAction: (() -> Void)? = nil
    @Entry var addRouteAction: (() -> Void)? = nil
}

/// Commands 블록에서 modelContext·coordinator 에 접근할 수 없으므로,
/// 워크스페이스 윈도우가 액션 클로저를 묶어서 FocusedValue 로 주입한다.
struct SegmentCommandHandler {
    var reload: () async throws -> Void
    var delete: () async throws -> Void
}

struct RouteCommandHandler {
    var export: () -> Void
    var redownload: () -> Void
    var delete: () -> Void
    var makeIntoCourse: () -> Void
    var canExport: Bool
}

struct CourseCommandHandler {
    var edit: () -> Void
}

struct CourseFileCommandHandler {
    var saveTCX: () -> Void
    var canSaveTCX: Bool
}
