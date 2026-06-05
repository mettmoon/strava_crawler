import SwiftUI
import SwiftData
import StravaTCXKit

struct MainTabView: View {
    @Environment(\.modelContext) private var context
    @Environment(ImportCoordinator.self) private var coordinator
    @Query(sort: \RouteRecord.createdAt, order: .reverse) private var routes: [RouteRecord]

    @State private var selection: SidebarItem?
    @State private var inspectorIsPresented = true
    @State private var showingMyRoutes = false
    @State private var showingLogin = false
    @State private var showingLoginAlert = false
    @State private var cachedCourse: TCXCourse?
    @State private var cachedRouteID: String?

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
        List(selection: $selection) {
            if !routes.isEmpty {
                Section {
                    ForEach(routes) { route in
                        RouteRow(route: route)
                            .tag(SidebarItem.route(route))
                    }
                    .onDelete(perform: deleteRoutes)
                } header: {
                    Label("경로", systemImage: "bicycle")
                }
            }

            if !segments.isEmpty {
                Section {
                    ForEach(segments) { segment in
                        SegmentRow(segment: segment)
                            .tag(SidebarItem.segment(segment))
                    }
                } header: {
                    Label("구간", systemImage: "mountain.2")
                }
            }
        }
        .navigationTitle("Strava TCX")
        .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        .overlay {
            if routes.isEmpty && segments.isEmpty {
                ContentUnavailableView {
                    Label("저장된 항목 없음", systemImage: "tray")
                } description: {
                    Text("+ 버튼으로 내 경로에서 가져오세요.")
                }
            }
        }
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
