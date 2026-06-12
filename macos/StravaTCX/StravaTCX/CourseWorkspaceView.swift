import SwiftUI
import SwiftData
import AppKit
import StravaTCXKit

/// 별도 윈도우에서 단일 코스를 보여주는 워크스페이스 (보기 전용).
/// 좌측 사이드바 없이, 가운데 지도 + 우측 CourseDetailView 인스펙터로 구성된다.
/// 3D 경로는 툴바의 버튼으로 별도 윈도우에서 띄운다.
/// 편집은 기존 `course-editor` 윈도우에서 한다.
struct CourseWorkspaceView: View {
    var courseID: UUID?
    var container: AppContainer

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(RouteListViewModel.self) private var routeVM
    @Query private var allCourses: [CourseRecord]

    @State private var highlightPoints: [TrackPoint] = []
    @State private var hoverInfo: RouteHoverInfo?
    @State private var selectedCueID: UUID?
    @State private var showDeleteConfirm = false
    @State private var rangeSelection: ChartRangeSelection?

    private var course: CourseRecord? {
        guard let id = courseID else { return nil }
        return allCourses.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let course {
                workspace(for: course)
                    .navigationTitle(course.title)
                    .navigationSubtitle("코스")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                openWindow(id: "course-3d", value: course.id)
                            } label: {
                                Label("3D 경로", systemImage: "view.3d")
                            }
                            .help("3D 경로를 별도 창에서 열기")
                        }
                    }
            } else if courseID == nil {
                ContentUnavailableView("코스를 찾을 수 없음", systemImage: "map")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .focusedSceneValue(\.courseCommandHandler, makeHandler())
        .confirmationDialog(
            course.map { "'\($0.title)'을(를) 삭제하시겠습니까?" } ?? "코스를 삭제하시겠습니까?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                guard let course else { return }
                context.delete(course)
                dismiss()
                NSApp.keyWindow?.close()
            }
        }
    }

    @ViewBuilder
    private func workspace(for course: CourseRecord) -> some View {
        let pts = course.allTrackPoints
        NavigationSplitView {
            CourseCuesheetSidebar(course: course, selectedCueID: $selectedCueID)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            contentPane(trackPoints: pts, course: course)
                .inspector(isPresented: .constant(true)) {
                    Group {
                        if let range = rangeSelection {
                            RangeStatsInspectorView(trackPoints: pts, range: range)
                        } else {
                            CourseCueInspectorView(course: course, selectedCueID: selectedCueID)
                        }
                    }
                    .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
                }
        }
        .onChange(of: course.cuePoints.map(\.id)) { _, ids in
            if let sel = selectedCueID, !ids.contains(sel) {
                selectedCueID = nil
            }
        }
    }

    @ViewBuilder
    private func contentPane(trackPoints pts: [TrackPoint], course: CourseRecord) -> some View {
        if pts.isEmpty {
            ContentUnavailableView {
                Label("경로 데이터 없음", systemImage: "map")
            } description: {
                Text("이 코스에는 아직 경로 데이터가 없습니다.")
            }
        } else {
            let focusKm = focusedDistanceKm(for: pts, course: course)
            VStack(spacing: 0) {
                RouteMapView(
                    trackPoints: pts,
                    highlightPoints: highlightPoints,
                    cuePoints: course.cuePoints,
                    focusedCueID: selectedCueID,
                    onDeselectFocus: { selectedCueID = nil },
                    onSelectCue: { selectedCueID = $0 },
                    hoverInfo: $hoverInfo,
                    rangeSelection: rangeSelection
                )
                Divider()
                ElevationChartView(
                    trackPoints: pts,
                    markers: markers(for: pts, course: course),
                    focusedDistanceKm: focusKm,
                    hoverInfo: $hoverInfo,
                    rangeSelection: $rangeSelection,
                    onBackgroundClick: { selectedCueID = nil }
                )
            }
        }
    }

    private func focusedDistanceKm(for pts: [TrackPoint], course: CourseRecord) -> Double? {
        guard let id = selectedCueID,
              let cue = course.cuePoints.first(where: { $0.id == id }),
              let idx = Geo.nearestIndex(pts, lat: cue.lat, lon: cue.lon) else { return nil }
        return pts[idx].cumKm
    }

    private func markers(for pts: [TrackPoint], course: CourseRecord) -> [ElevationMarker] {
        course.cuePoints.compactMap { cue in
            guard let idx = Geo.nearestIndex(pts, lat: cue.lat, lon: cue.lon) else { return nil }
            return ElevationMarker(
                id: cue.id.uuidString,
                cumKm: pts[idx].cumKm,
                label: cue.name,
                color: .cyan
            )
        }
    }

    // MARK: - Command Handler

    private func makeHandler() -> CourseCommandHandler? {
        guard let course else { return nil }
        return CourseCommandHandler(
            edit: { openWindow(id: "course-editor", value: course.id) },
            exportTCX: { exportCourseTCX(course) },
            delete: { showDeleteConfirm = true }
        )
    }

    private func exportCourseTCX(_ course: CourseRecord) {
        let allPts = course.allTrackPoints
        guard !allPts.isEmpty else { NSSound.beep(); return }

        let cueSpecs = course.cuePoints.compactMap { cue -> TCXCourse.CuePointSpec? in
            guard let ni = Geo.nearestIndex(allPts, lat: cue.lat, lon: cue.lon) else { return nil }
            return TCXCourse.CuePointSpec(
                idx: ni, time: allPts[ni].time,
                lat: cue.lat, lon: cue.lon, ele: allPts[ni].ele,
                name: cue.name, pointType: cue.pointType, notes: cue.notes
            )
        }

        guard let sourceID = course.sourceRouteID,
              let sourceRoute = routeVM.routes.first(where: { $0.id == sourceID }),
              let tcxCourse = try? TCXCourse(data: sourceRoute.tcxData) else {
            NSSound.beep(); return
        }

        guard let result = try? tcxCourse.buildFromCourse(cuePoints: cueSpecs) else {
            NSSound.beep(); return
        }
        Exporter.saveSingle(filename: "\(course.title)", data: result.data)
    }
}
