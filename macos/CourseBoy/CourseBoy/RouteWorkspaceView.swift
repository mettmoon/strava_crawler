import SwiftUI
import AppKit
import CourseBoyKit

/// 별도 윈도우에서 단일 경로(라우트)를 코스로 변환하기 전에 확인하는 임시 워크스페이스.
/// 좌측 사이드바에서 포함할 구간을 고르고, 가운데 지도 + 우측 RouteDetailView 인스펙터로 확인한다.
/// 3D 경로는 툴바의 버튼으로 별도 윈도우에서 띄운다.
struct RouteWorkspaceView: View {
    var routeID: String?
    var container: AppContainer

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(\.newDocument) private var newDocument
    @Environment(RouteListViewModel.self) private var routeVM

    @State private var parsedCourse: TCXCourse?
    @State private var highlightPoints: [TrackPoint] = []
    @State private var routeHoverInfo: RouteHoverInfo?
    @State private var showDeleteConfirm = false
    @State private var rangeSelection: ChartRangeSelection?
    @State private var pinnedDistanceKm: Double?
    @State private var selectedSegmentRouteID: String?
    @State private var selectedSegmentIDs: Set<String> = []
    @State private var highlightedSegmentID: String?

    private var route: Route? {
        guard let id = routeID else { return nil }
        return routeVM.routes.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let route {
                workspace(for: route)
                    .navigationTitle(route.title)
                    .navigationSubtitle("코스 만들기")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                makeCourseFromCurrentSelection(route: route)
                            } label: {
                                Label("코스 만들기", systemImage: "checkmark.circle")
                            }
                            .disabled(parsedCourse == nil)
                        }

                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                openWindow(id: "route-3d", value: route.id)
                            } label: {
                                Label("3D 경로", systemImage: "view.3d")
                            }
                            .help("3D 경로를 별도 창에서 열기")
                        }
                    }
            } else if routeID == nil {
                ContentUnavailableView("경로를 찾을 수 없음", systemImage: "bicycle")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .focusedSceneValue(\.routeCommandHandler, makeHandler())
        .confirmationDialog(
            route.map { "'\($0.title)'을(를) 삭제하시겠습니까?" } ?? "경로를 삭제하시겠습니까?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                guard let id = route?.id else { return }
                Task {
                    await routeVM.delete(routeID: id)
                    await MainActor.run {
                        dismiss()
                        NSApp.keyWindow?.close()
                    }
                }
            }
        } message: {
            Text("TCX 데이터와 세그먼트 정보가 삭제됩니다.")
        }
    }

    @ViewBuilder
    private func workspace(for route: Route) -> some View {
        NavigationSplitView {
            RouteCourseBuilderSidebar(
                route: route,
                selectedSegmentIDs: $selectedSegmentIDs,
                highlightedSegmentID: $highlightedSegmentID,
                createDisabled: parsedCourse == nil,
                onCreate: {
                    makeCourseFromCurrentSelection(route: route)
                }
            )
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
        } detail: {
            contentPane
                .inspector(isPresented: .constant(true)) {
                    ZStack {
                        // RouteDetailView는 항상 mount 상태로 둬서 parsedCourse/highlight 콜백을 유지.
                        RouteDetailView(
                            route: route,
                            onCourseParsed: { parsedCourse = $0 },
                            onHighlight: { highlightPoints = $0 }
                        )
                        .opacity(rangeSelection == nil && pinnedDistanceKm == nil ? 1 : 0)
                        .allowsHitTesting(rangeSelection == nil && pinnedDistanceKm == nil)

                        if rangeSelection != nil || pinnedDistanceKm != nil {
                            SelectionInspectorStack(
                                trackPoints: parsedCourse?.trackPoints ?? [],
                                rangeSelection: rangeSelection,
                                pinnedDistanceKm: pinnedDistanceKm,
                                onClearPin: { pinnedDistanceKm = nil }
                            )
                            .background(.background)
                        }
                    }
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                }
        }
        .task(id: route.id) {
            syncSegmentSelection(for: route)
            pinnedDistanceKm = nil
            rangeSelection = nil
            highlightedSegmentID = nil
        }
        .onChange(of: route.segments.map(\.segmentID)) { _, _ in
            syncSegmentSelection(for: route)
        }
    }

    @ViewBuilder
    private var contentPane: some View {
        let pts = parsedCourse?.trackPoints ?? []
        if pts.isEmpty {
            ContentUnavailableView {
                Label("경로 데이터 없음", systemImage: "map")
            } description: {
                Text("경로가 처리되면 지도가 표시됩니다.")
            }
        } else {
            let highlightSegment = highlightedSegment
            let sidebarHighlightPoints = highlightSegment.map { sliceTrackPoints(pts, for: $0) } ?? []
            let mapHighlight = sidebarHighlightPoints.isEmpty ? highlightPoints : sidebarHighlightPoints
            VStack(spacing: 0) {
                RouteMapView(
                    trackPoints: pts,
                    highlightPoints: mapHighlight,
                    cuePoints: cuePoints(for: pts),
                    hoverInfo: $routeHoverInfo,
                    rangeSelection: rangeSelection,
                    pinnedDistanceKm: pinnedDistanceKm,
                    onPinDistance: { km in
                        pinnedDistanceKm = km
                    }
                )
                Divider()
                ElevationChartView(
                    trackPoints: pts,
                    markers: markers(for: pts),
                    hoverInfo: $routeHoverInfo,
                    rangeSelection: $rangeSelection,
                    pinnedDistanceKm: $pinnedDistanceKm,
                    highlightedRangeKm: highlightedRangeKm(for: sidebarHighlightPoints)
                )
            }
        }
    }

    private var highlightedSegment: SegmentInfo? {
        guard let id = highlightedSegmentID else { return nil }
        return route?.segments.first { $0.segmentID == id }
    }

    private func sliceTrackPoints(_ pts: [TrackPoint], for seg: SegmentInfo) -> [TrackPoint] {
        guard let sp = seg.startPoint, let ep = seg.endPoint else { return [] }
        let startIdx = Geo.nearestIndex(pts, lat: sp[0], lon: sp[1]) ?? 0
        let endIdx = Geo.nearestIndex(pts, lat: ep[0], lon: ep[1], startIdx: startIdx + 1) ?? (pts.count - 1)
        guard startIdx < endIdx else { return [] }
        return Array(pts[startIdx...endIdx])
    }

    private func highlightedRangeKm(for slice: [TrackPoint]) -> ClosedRange<Double>? {
        guard let first = slice.first, let last = slice.last, last.cumKm > first.cumKm else { return nil }
        return first.cumKm...last.cumKm
    }

    // MARK: - Cue / Marker

    private func cuePoints(for pts: [TrackPoint]) -> [CourseCuePoint] {
        guard let route, let course = parsedCourse else { return [] }
        return Cuesheet.makeEntries(
            trackPoints: course.trackPoints,
            segments: selectedSegments(for: route),
            minCategory: nil
        ).entries.map { entry in
            CourseCuePoint(lat: entry.lat, lon: entry.lon,
                           name: entry.baseName, pointType: entry.pointType)
        }
    }

    private func markers(for pts: [TrackPoint]) -> [ElevationMarker] {
        guard let route, let course = parsedCourse, !pts.isEmpty else { return [] }
        return Cuesheet.makeEntries(
            trackPoints: course.trackPoints,
            segments: selectedSegments(for: route),
            minCategory: nil
        ).entries.map { entry in
            ElevationMarker(
                id: "\(entry.idx)-\(entry.isStart)",
                cumKm: pts[min(entry.idx, pts.count - 1)].cumKm,
                label: entry.baseName,
                color: entry.isStart ? .cyan : .purple
            )
        }
    }

    // MARK: - Command Handler

    private func makeHandler() -> RouteCommandHandler? {
        guard let route else { return nil }
        return RouteCommandHandler(
            export: {
                guard let course = parsedCourse else { NSSound.beep(); return }
                let entries = Cuesheet.makeEntries(
                    trackPoints: course.trackPoints,
                    segments: route.segments,
                    minCategory: route.minCategory
                ).entries
                guard let cued = try? course.build(entries: entries, forRWGPS: false),
                      let rwgps = try? course.build(entries: entries, forRWGPS: true) else {
                    NSSound.beep(); return
                }
                Exporter.saveToFolder(prefix: route.fileNamePrefix, cued: cued.data, rwgps: rwgps.data)
            },
            redownload: {
                routeVM.retry(routeID: route.id)
            },
            delete: {
                showDeleteConfirm = true
            },
            makeIntoCourse: {
                makeCourseFromCurrentSelection(route: route)
            },
            canExport: parsedCourse != nil
        )
    }

    // MARK: - Course 생성

    private func syncSegmentSelection(for route: Route) {
        let validIDs = Set(route.segments.map(\.segmentID))
        if selectedSegmentRouteID != route.id {
            selectedSegmentRouteID = route.id
            selectedSegmentIDs = validIDs
            return
        }

        selectedSegmentIDs = selectedSegmentIDs.intersection(validIDs)
        if selectedSegmentIDs.isEmpty, !validIDs.isEmpty {
            selectedSegmentIDs = validIDs
        }
    }

    private func selectedSegments(for route: Route) -> [SegmentInfo] {
        route.segments.filter { selectedSegmentIDs.contains($0.segmentID) }
    }

    private func makeCourseFromCurrentSelection(route: Route) {
        guard let course = parsedCourse else { NSSound.beep(); return }
        makeCourseFromRoute(route: route, tcxCourse: course, selectedSegments: selectedSegments(for: route))
    }

    private func makeCourseFromRoute(route: Route, tcxCourse: TCXCourse, selectedSegments: [SegmentInfo]) {
        let pts = tcxCourse.trackPoints
        guard !pts.isEmpty else { NSSound.beep(); return }

        let newCourse = CourseRecord(title: route.title, sourceRouteID: route.id)
        newCourse.segmentSnapshots = selectedSegments.map(CourseSegmentSnapshot.init(segment:))
        newCourse.routePoints = [
            CourseRoutePoint(lat: pts.first!.lat, lon: pts.first!.lon),
            CourseRoutePoint(lat: pts.last!.lat, lon: pts.last!.lon),
        ]
        newCourse.trackSegments = [pts.map { TrackPointCodable($0) }]

        let cuesheetResult = Cuesheet.makeEntries(
            trackPoints: pts,
            segments: selectedSegments,
            minCategory: nil
        )
        newCourse.cuePoints = cuesheetResult.entries.map { entry in
            let displayName: String
            if entry.isStart {
                let meta = [Classification.normalizeDistanceText(entry.dist), Classification.formatGrade(entry.grade)]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                let prefix = entry.gradeClass.arrow + (meta.isEmpty ? "" : meta + " ")
                displayName = prefix
            } else {
                displayName = "🏁" + Classification.resolveSegmentName(entry.segName)
            }
            return CourseCuePoint(
                lat: entry.lat, lon: entry.lon,
                name: displayName, pointType: entry.pointType,
                notes: entry.baseNotes,
                distanceMeters: pts.indices.contains(entry.idx) ? pts[entry.idx].cumKm * 1000 : 0
            )
        }

        newDocument { CourseDocument(course: newCourse) }
        dismiss()
    }
}
