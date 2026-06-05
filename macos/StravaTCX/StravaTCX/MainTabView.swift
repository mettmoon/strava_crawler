import SwiftUI
import SwiftData
import AppKit
import StravaTCXKit

private enum SidebarTab { case routes, segments, courses }

struct MainTabView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(RouteListViewModel.self) private var routeVM
    @Query(sort: \CourseRecord.createdAt, order: .reverse) private var courses: [CourseRecord]
    @Environment(\.modelContext) private var context

    @State private var selection: SidebarItem?
    @State private var sidebarTab: SidebarTab = .routes
    @State private var inspectorIsPresented = true
    @State private var showingMyRoutes = false
    @State private var showingLogin = false
    @State private var showingLoginAlert = false
    @State private var parsedCourse: TCXCourse?
    @State private var showRouteDeleteConfirm = false
    @State private var showCourseDeleteConfirm = false
    @State private var highlightPoints: [TrackPoint] = []

    // MARK: - computed

    private var segments: [SegmentInfo] {
        var seen = Set<String>()
        var result: [SegmentInfo] = []
        for route in routeVM.routes {
            for seg in route.segments where seen.insert(seg.segmentID).inserted {
                result.append(seg)
            }
        }
        return result.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private var selectedTrackPoints: [TrackPoint] {
        switch selection {
        case .route:           return parsedCourse?.trackPoints ?? []
        case .segment(let s):  return trackPoints(for: s)
        case .course(let c):   return c.allTrackPoints
        case nil:              return []
        }
    }

    private var selectedCuePoints: [CourseCuePoint] {
        switch selection {
        case .course(let c):
            return c.cuePoints
        case .route(let route):
            guard let course = parsedCourse else { return [] }
            return Cuesheet.makeEntries(
                trackPoints: course.trackPoints,
                segments: route.segments,
                minCategory: route.minCategory
            ).entries.map { entry in
                CourseCuePoint(lat: entry.lat, lon: entry.lon,
                               name: entry.baseName, pointType: entry.pointType)
            }
        default:
            return []
        }
    }

    private var selectedMarkers: [ElevationMarker] {
        let pts = selectedTrackPoints
        guard !pts.isEmpty else { return [] }
        switch selection {
        case .route(let route):
            guard let course = parsedCourse else { return [] }
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
        case .course(let c):
            return c.cuePoints.compactMap { cue in
                guard let idx = Geo.nearestIndex(pts, lat: cue.lat, lon: cue.lon) else { return nil }
                return ElevationMarker(
                    id: cue.id.uuidString,
                    cumKm: pts[idx].cumKm,
                    label: cue.name,
                    color: .cyan
                )
            }
        default:
            return []
        }
    }

    // MARK: - body

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            contentPane
                .inspector(isPresented: $inspectorIsPresented) {
                    inspectorPane
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: selection) { _, _ in
            highlightPoints = []
            parsedCourse = nil
        }
        .focusedSceneValue(\.routeCommandHandler, {
            guard case .route(let route) = selection else { return nil }
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
                    showRouteDeleteConfirm = true
                },
                makeIntoCourse: {
                    guard let course = parsedCourse else { NSSound.beep(); return }
                    makeCourseFromRoute(route: route, tcxCourse: course)
                },
                canExport: parsedCourse != nil
            )
        }())
        .confirmationDialog(
            {
                if case .route(let r) = selection { return "'\(r.title)'을(를) 삭제하시겠습니까?" }
                return "경로를 삭제하시겠습니까?"
            }(),
            isPresented: $showRouteDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if case .route(let r) = selection {
                    Task { await routeVM.delete(routeID: r.id) }
                    selection = nil
                }
            }
        } message: {
            Text("TCX 데이터와 세그먼트 정보가 삭제됩니다.")
        }
        .confirmationDialog(
            {
                if case .course(let c) = selection { return "'\(c.title)'을(를) 삭제하시겠습니까?" }
                return "코스를 삭제하시겠습니까?"
            }(),
            isPresented: $showCourseDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                if case .course(let c) = selection {
                    context.delete(c)
                    selection = nil
                }
            }
        }
        .focusedSceneValue(\.courseCommandHandler, {
            guard case .course(let c) = selection else { return nil }
            return CourseCommandHandler(
                edit: { openWindow(id: "course-editor", value: c.id) },
                exportTCX: { exportCourseTCX(c) },
                delete: { showCourseDeleteConfirm = true }
            )
        }())
        .focusedSceneValue(\.createCourseAction, { createCourse() })
        .focusedSceneValue(\.addRouteAction, { addTapped() })
        .focusedSceneValue(\.selectedSegment, {
            guard case .segment(let s) = selection else { return nil }
            return s
        }())
        .focusedSceneValue(\.segmentCommandHandler, {
            guard case .segment(let s) = selection else { return nil }
            return SegmentCommandHandler(
                reload: {
                    try? await routeVM.reloadSegment(segmentID: s.segmentID)
                },
                delete: {
                    try? await routeVM.deleteSegment(segmentID: s.segmentID)
                    selection = nil
                }
            )
        }())
        .task { await routeVM.reconcile() }
        .task { await routeVM.load() }
        .sheet(isPresented: $showingMyRoutes) {
            MyRoutesView { routeVM.importRoute($0) }
        }
        .sheet(isPresented: $showingLogin, onDismiss: {
            if !AppSettings.cookie.isEmpty { showingMyRoutes = true }
        }) {
            StravaLoginView { value, csrf in
                AppSettings.cookie = value
                if let csrf { AppSettings.csrfToken = csrf }
            }
        }
        .alert("로그인해야 합니다", isPresented: $showingLoginAlert) {
            Button("로그인") { showingLogin = true }
            Button("취소", role: .cancel) {}
        } message: {
            Text("Strava 라우트를 추가하려면 먼저 Strava 에 로그인해야 합니다.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            Picker("", selection: $sidebarTab) {
                Text("경로").tag(SidebarTab.routes)
                Text("구간").tag(SidebarTab.segments)
                Text("코스").tag(SidebarTab.courses)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            let isEmpty: Bool = {
                switch sidebarTab {
                case .routes:   return routeVM.routes.isEmpty
                case .segments: return segments.isEmpty
                case .courses:  return courses.isEmpty
                }
            }()
            if isEmpty {
                ContentUnavailableView {
                    Label(
                        {
                            switch sidebarTab {
                            case .routes:   return "경로 없음"
                            case .segments: return "구간 없음"
                            case .courses:  return "코스 없음"
                            }
                        }(),
                        systemImage: sidebarTab == .routes ? "bicycle" : sidebarTab == .segments ? "mountain.2" : "map"
                    )
                } description: {
                    if sidebarTab == .routes {
                        Text("+ 버튼으로 내 경로에서 가져오세요.")
                    } else if sidebarTab == .courses {
                        Text("메뉴 > 코스 > 새 코스로 만들거나\n경로 메뉴에서 \"코스로 만들기\"를 사용하세요.")
                    }
                }
            } else {
                List(selection: $selection) {
                    switch sidebarTab {
                    case .routes:
                        ForEach(routeVM.routes) { route in
                            RouteRow(route: route, progress: routeVM.progress(for: route.id))
                                .tag(SidebarItem.route(route))
                        }
                    case .segments:
                        ForEach(segments) { segment in
                            SegmentRow(segment: segment)
                                .tag(SidebarItem.segment(segment))
                        }
                    case .courses:
                        ForEach(courses) { course in
                            CourseRow(course: course)
                                .tag(SidebarItem.course(course))
                        }
                        .onDelete(perform: deleteCourses)
                    }
                }
            }
        }
        .navigationTitle("Strava TCX")
        .navigationSplitViewColumnWidth(min: 220, ideal: 240)
    }

    // MARK: - Content (지도 + 3D 탭)

    @ViewBuilder
    private var contentPane: some View {
        if selectedTrackPoints.isEmpty {
            ContentUnavailableView {
                Label("항목을 선택하세요", systemImage: "map")
            } description: {
                Text("왼쪽 목록에서 경로나 구간을 선택하면 지도가 표시됩니다.")
            }
        } else {
            TabView {
                Tab("지도", systemImage: "map.fill") {
                    VStack(spacing: 0) {
                        RouteMapView(trackPoints: selectedTrackPoints, highlightPoints: highlightPoints, cuePoints: selectedCuePoints)
                        Divider()
                        ElevationChartView(trackPoints: selectedTrackPoints, markers: selectedMarkers)
                    }
                }
                Tab("3D 경로", systemImage: "mountain.2.fill") {
                    Route3DView(trackPoints: selectedTrackPoints, highlightPoints: highlightPoints)
                }
            }
            .tabViewStyle(.tabBarOnly)
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspectorPane: some View {
        switch selection {
        case .route(let route):
            RouteDetailView(route: route, onCourseParsed: { course in
                parsedCourse = course
            }, onHighlight: { pts in
                highlightPoints = pts
            })
        case .segment(let segment):
            SegmentDetailView(segment: segment, onHighlight: { pts in
                highlightPoints = pts
            })
        case .course(let course):
            CourseDetailView(course: course)
        case nil:
            ContentUnavailableView {
                Label("선택 없음", systemImage: "sidebar.right")
            } description: {
                Text("왼쪽에서 경로나 구간을 선택하세요.")
            }
        }
    }

    // MARK: - 액션

    private func addTapped() {
        if AppSettings.cookie.isEmpty { showingLoginAlert = true }
        else { showingMyRoutes = true }
    }

    private func createCourse() {
        let newCourse = CourseRecord(title: "새 코스 \(courses.count + 1)")
        context.insert(newCourse)
        sidebarTab = .courses
        selection = .course(newCourse)
    }

    private func deleteCourses(_ offsets: IndexSet) {
        for i in offsets { context.delete(courses[i]) }
    }

    private func makeCourseFromRoute(route: Route, tcxCourse: TCXCourse) {
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
            segments: route.segments,
            minCategory: route.minCategory
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
        sidebarTab = .courses
        selection = .course(newCourse)
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
        Exporter.saveSingle(prefix: "course_\(course.id.uuidString.prefix(8))", data: result.data)
    }
}
