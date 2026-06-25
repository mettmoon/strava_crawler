import SwiftUI
import AppKit
import CourseBoyKit

/// 별도 윈도우에서 단일 코스를 보여주는 워크스페이스 (보기 전용).
/// 좌측 사이드바 없이, 가운데 지도 + 우측 CourseDetailView 인스펙터로 구성된다.
/// 3D 경로와 편집 화면은 문서 뷰가 전달한 액션으로 전환한다.
struct CourseWorkspaceView: View {
    @ObservedObject var course: CourseRecord
    var container: AppContainer
    var onEdit: () -> Void
    var onShow3D: () -> Void

    @State private var highlightPoints: [TrackPoint] = []
    @State private var hoverInfo: RouteHoverInfo?
    @State private var selectedCueIDs: Set<UUID> = []
    @State private var rangeSelection: ChartRangeSelection?
    @State private var isInspectorPresented = true

    private var selectedCueID: UUID? {
        selectedCueIDs.count == 1 ? selectedCueIDs.first : nil
    }

    var body: some View {
        workspace(for: course)
            .navigationTitle(course.title)
            .navigationSubtitle("코스")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: onEdit) {
                        Label("편집", systemImage: "pencil")
                    }
                    .help("코스 편집")
                }

                ToolbarItem(placement: .primaryAction) {
                    Button(action: onShow3D) {
                        Label("3D 경로", systemImage: "view.3d")
                    }
                    .disabled(course.allTrackPoints.isEmpty)
                    .help("3D 경로 보기")
                }

                ToolbarItem(placement: .primaryAction) {
                    InspectorToggleButton(isPresented: $isInspectorPresented)
                }
            }
            .toolbar(removing: .sidebarToggle)
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
                .inspector(isPresented: $isInspectorPresented) {
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
        return CourseCommandHandler(
            edit: onEdit
        )
    }

    private func makeFileHandler() -> CourseFileCommandHandler? {
        return CourseFileCommandHandler(
            exportTCX: { saveCourseTCX(course) },
            canExportTCX: !course.allTrackPoints.isEmpty
        )
    }

    private func saveCourseTCX(_ course: CourseRecord) {
        Exporter.saveTCX(filename: course.title) { options in
            let cues = applyExportOptions(options, to: course.cuePoints)
            return try? CourseTCXFileCoder.makeTCXData(
                title: course.title,
                trackPoints: course.allTrackPoints,
                cuePoints: cues
            )
        }
    }

    private func applyExportOptions(_ options: TCXExportOptions, to cuePoints: [CourseCuePoint]) -> [CourseCuePoint] {
        guard options.useNameAsNotes else { return cuePoints }
        return cuePoints.map { cue in
            var copy = cue
            copy.notes = cue.name
            return copy
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
