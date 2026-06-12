import SwiftUI
import SwiftData
import AppKit
import StravaTCXKit

/// 별도 윈도우에서 단일 경로(라우트)를 보여주는 워크스페이스.
/// 좌측 사이드바 없이, 가운데 지도/3D 탭 + 우측 RouteDetailView 인스펙터로 구성된다.
struct RouteWorkspaceView: View {
    var routeID: String?
    var container: AppContainer

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(RouteListViewModel.self) private var routeVM
    @Query(sort: \CourseRecord.createdAt, order: .reverse) private var courses: [CourseRecord]

    @State private var parsedCourse: TCXCourse?
    @State private var highlightPoints: [TrackPoint] = []
    @State private var routeHoverInfo: RouteHoverInfo?
    @State private var showDeleteConfirm = false
    @State private var routePendingCourseCreation: Route?
    @State private var rangeSelection: ChartRangeSelection?

    private var route: Route? {
        guard let id = routeID else { return nil }
        return routeVM.routes.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let route {
                workspace(for: route)
                    .navigationTitle(route.title)
                    .navigationSubtitle("경로")
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
        .sheet(item: $routePendingCourseCreation) { route in
            RouteSegmentSelectionSheet(route: route) { selectedSegments in
                guard let course = parsedCourse else { NSSound.beep(); return }
                makeCourseFromRoute(route: route, tcxCourse: course, selectedSegments: selectedSegments)
            }
        }
    }

    @ViewBuilder
    private func workspace(for route: Route) -> some View {
        contentPane
            .inspector(isPresented: .constant(true)) {
                ZStack {
                    // RouteDetailView는 항상 mount 상태로 둬서 parsedCourse/highlight 콜백을 유지.
                    RouteDetailView(
                        route: route,
                        onCourseParsed: { parsedCourse = $0 },
                        onHighlight: { highlightPoints = $0 }
                    )
                    .opacity(rangeSelection == nil ? 1 : 0)
                    .allowsHitTesting(rangeSelection == nil)

                    if let range = rangeSelection {
                        RangeStatsInspectorView(
                            trackPoints: parsedCourse?.trackPoints ?? [],
                            range: range
                        )
                        .background(.background)
                    }
                }
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
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
            TabView {
                Tab("지도", systemImage: "map.fill") {
                    VStack(spacing: 0) {
                        RouteMapView(
                            trackPoints: pts,
                            highlightPoints: highlightPoints,
                            cuePoints: cuePoints(for: pts),
                            hoverInfo: $routeHoverInfo,
                            rangeSelection: rangeSelection
                        )
                        Divider()
                        ElevationChartView(
                            trackPoints: pts,
                            markers: markers(for: pts),
                            hoverInfo: $routeHoverInfo,
                            rangeSelection: $rangeSelection
                        )
                    }
                }
                Tab("3D 경로", systemImage: "mountain.2.fill") {
                    Route3DView(trackPoints: pts, highlightPoints: highlightPoints)
                }
            }
            .tabViewStyle(.tabBarOnly)
        }
    }

    // MARK: - Cue / Marker

    private func cuePoints(for pts: [TrackPoint]) -> [CourseCuePoint] {
        guard let route, let course = parsedCourse else { return [] }
        return Cuesheet.makeEntries(
            trackPoints: course.trackPoints,
            segments: route.segments,
            minCategory: route.minCategory
        ).entries.map { entry in
            CourseCuePoint(lat: entry.lat, lon: entry.lon,
                           name: entry.baseName, pointType: entry.pointType)
        }
    }

    private func markers(for pts: [TrackPoint]) -> [ElevationMarker] {
        guard let route, let course = parsedCourse, !pts.isEmpty else { return [] }
        return Cuesheet.makeEntries(
            trackPoints: course.trackPoints,
            segments: route.segments,
            minCategory: route.minCategory
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
                guard parsedCourse != nil else { NSSound.beep(); return }
                routePendingCourseCreation = route
            },
            canExport: parsedCourse != nil
        )
    }

    // MARK: - Course 생성

    private func makeCourseFromRoute(route: Route, tcxCourse: TCXCourse, selectedSegments: [SegmentInfo]) {
        let pts = tcxCourse.trackPoints
        guard !pts.isEmpty else { NSSound.beep(); return }

        let newCourse = CourseRecord(title: route.title, sourceRouteID: route.id)
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

        context.insert(newCourse)
    }
}
