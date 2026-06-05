import SwiftUI
import SwiftData
import AppKit
import StravaTCXKit

private enum SidebarTab { case routes, segments }

struct MainTabView: View {
    @Environment(\.modelContext) private var context
    @Environment(ImportCoordinator.self) private var coordinator
    @Query(sort: \RouteRecord.createdAt, order: .reverse) private var routes: [RouteRecord]

    @State private var selection: SidebarItem?
    @State private var sidebarTab: SidebarTab = .routes
    @State private var inspectorIsPresented = true
    @State private var showingMyRoutes = false
    @State private var showingLogin = false
    @State private var showingLoginAlert = false
    @State private var cachedCourse: TCXCourse?
    @State private var cachedRouteID: String?
    @State private var showRouteDeleteConfirm = false

    // MARK: - computed

    private var segments: [SegmentInfo] {
        var seen = Set<String>()
        var result: [SegmentInfo] = []
        for route in routes {
            for seg in route.segments where seen.insert(seg.segmentID).inserted {
                result.append(seg)
            }
        }
        return result.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    private var selectedTrackPoints: [TrackPoint] {
        switch selection {
        case .route:          return cachedCourse?.trackPoints ?? []
        case .segment(let s): return trackPoints(for: s)
        case nil:             return []
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
        .onChange(of: selection) { _, newVal in
            guard case .route(let r) = newVal, r.status == .ready, !r.tcxData.isEmpty else {
                cachedCourse = nil; cachedRouteID = nil; return
            }
            guard cachedRouteID != r.routeID else { return }
            cachedCourse = try? TCXCourse(data: r.tcxData)
            cachedRouteID = r.routeID
        }
        .focusedSceneValue(\.routeCommandHandler, {
            guard case .route(let record) = selection else { return nil }
            return RouteCommandHandler(
                export: {
                    guard let course = cachedCourse else { NSSound.beep(); return }
                    let entries = Cuesheet.makeEntries(
                        trackPoints: course.trackPoints,
                        segments: record.segments,
                        minCategory: record.minCategory
                    ).entries
                    guard let cued = try? course.build(entries: entries, forRWGPS: false),
                          let rwgps = try? course.build(entries: entries, forRWGPS: true) else {
                        NSSound.beep(); return
                    }
                    Exporter.saveToFolder(prefix: record.fileNamePrefix, cued: cued.data, rwgps: rwgps.data)
                },
                redownload: {
                    coordinator.redownload(record)
                },
                delete: {
                    showRouteDeleteConfirm = true
                },
                canExport: cachedCourse != nil
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
                    context.delete(r)
                    selection = nil
                }
            }
        } message: {
            Text("TCX 데이터와 세그먼트 정보가 삭제됩니다.")
        }
        .focusedSceneValue(\.selectedSegment, {
            guard case .segment(let s) = selection else { return nil }
            return s
        }())
        .focusedSceneValue(\.segmentCommandHandler, {
            guard case .segment(let s) = selection else { return nil }
            return SegmentCommandHandler(
                reload: {
                    await coordinator.reloadSegment(s.segmentID, context: context)
                },
                delete: {
                    coordinator.deleteSegment(s.segmentID, context: context)
                    selection = nil
                }
            )
        }())
        .task { coordinator.reconcileOnLaunch(context: context) }
        .sheet(isPresented: $showingMyRoutes) {
            MyRoutesView { coordinator.importRoute($0, into: context) }
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
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            let isEmpty = sidebarTab == .routes ? routes.isEmpty : segments.isEmpty
            if isEmpty {
                ContentUnavailableView {
                    Label(
                        sidebarTab == .routes ? "경로 없음" : "구간 없음",
                        systemImage: sidebarTab == .routes ? "bicycle" : "mountain.2"
                    )
                } description: {
                    if sidebarTab == .routes {
                        Text("+ 버튼으로 내 경로에서 가져오세요.")
                    }
                }
            } else {
                List(selection: $selection) {
                    switch sidebarTab {
                    case .routes:
                        ForEach(routes) { route in
                            RouteRow(route: route)
                                .tag(SidebarItem.route(route))
                        }
                        .onDelete(perform: deleteRoutes)
                    case .segments:
                        ForEach(segments) { segment in
                            SegmentRow(segment: segment)
                                .tag(SidebarItem.segment(segment))
                        }
                    }
                }
            }
        }
        .navigationTitle("Strava TCX")
        .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: addTapped) {
                    Label("추가하기", systemImage: "plus")
                }
            }
        }
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
                    RouteMapView(trackPoints: selectedTrackPoints)
                }
                Tab("3D 경로", systemImage: "mountain.2.fill") {
                    Route3DView(trackPoints: selectedTrackPoints)
                }
            }
            .tabViewStyle(.tabBarOnly)
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspectorPane: some View {
        switch selection {
        case .route(let record):
            RouteDetailView(record: record)
        case .segment(let segment):
            SegmentDetailView(segment: segment)
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

    private func deleteRoutes(_ offsets: IndexSet) {
        for i in offsets { context.delete(routes[i]) }
    }
}
