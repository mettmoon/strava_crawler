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
    @Query private var allCourses: [CourseRecord]

    @State private var highlightPoints: [TrackPoint] = []
    @State private var hoverInfo: RouteHoverInfo?
    @State private var selectedCueIDs: Set<UUID> = []
    @State private var rangeSelection: ChartRangeSelection?

    private var course: CourseRecord? {
        guard let id = courseID else { return nil }
        return allCourses.first { $0.id == id }
    }

    private var selectedCueID: UUID? {
        selectedCueIDs.count == 1 ? selectedCueIDs.first : nil
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
        .focusedSceneValue(\.courseFileCommandHandler, makeFileHandler())
    }

    @ViewBuilder
    private func workspace(for course: CourseRecord) -> some View {
        let pts = course.allTrackPoints
        NavigationSplitView {
            CourseCuesheetSidebar(course: course, selectedCueIDs: $selectedCueIDs)
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
        .onChange(of: selectedCueIDs) { _, ids in
            syncRangeSelectionFromCueSelection(ids, trackPoints: pts, course: course)
        }
        .onChange(of: course.cuePoints.map(\.id)) { _, ids in
            let validIDs = Set(ids)
            let validSelection = selectedCueIDs.intersection(validIDs)
            if selectedCueIDs != validSelection {
                selectedCueIDs = validSelection
            } else {
                syncRangeSelectionFromCueSelection(validSelection, trackPoints: pts, course: course)
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
                    onDeselectFocus: {
                        selectedCueIDs.removeAll()
                        rangeSelection = nil
                    },
                    onSelectCue: {
                        selectedCueIDs = [$0]
                        rangeSelection = nil
                    },
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
                    onBackgroundClick: { selectedCueIDs.removeAll() }
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
            edit: { openWindow(id: "course-editor", value: course.id) }
        )
    }

    private func makeFileHandler() -> CourseFileCommandHandler? {
        guard let course else { return nil }
        return CourseFileCommandHandler(
            saveTCX: { saveCourseTCX(course) },
            canSaveTCX: !course.allTrackPoints.isEmpty
        )
    }

    private func saveCourseTCX(_ course: CourseRecord) {
        do {
            let data = try CourseTCXFileCoder.makeTCXData(from: course)
            Exporter.saveTCX(filename: course.title, data: data)
        } catch {
            NSSound.beep()
        }
    }

    private func syncRangeSelectionFromCueSelection(
        _ ids: Set<UUID>,
        trackPoints pts: [TrackPoint],
        course: CourseRecord
    ) {
        guard ids.count == 2 else {
            if rangeSelection?.isDragging != true {
                rangeSelection = nil
            }
            return
        }

        let selectedCues = course.cuePoints
            .filter { ids.contains($0.id) }
            .sorted { $0.distanceMeters < $1.distanceMeters }
        guard selectedCues.count == 2 else {
            rangeSelection = nil
            return
        }

        let startKm = cueDistanceKm(selectedCues[0], trackPoints: pts)
        let endKm = cueDistanceKm(selectedCues[1], trackPoints: pts)
        guard abs(endKm - startKm) > 0 else {
            rangeSelection = nil
            return
        }

        rangeSelection = ChartRangeSelection(startKm: startKm, endKm: endKm, isDragging: false)
    }

    private func cueDistanceKm(_ cue: CourseCuePoint, trackPoints pts: [TrackPoint]) -> Double {
        if let idx = Geo.nearestIndex(pts, lat: cue.lat, lon: cue.lon) {
            return pts[idx].cumKm
        }
        return cue.distanceMeters / 1000
    }
}
