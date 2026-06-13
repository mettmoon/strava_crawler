import SwiftUI
import CourseBoyKit

/// 코스로 변환할 경로(라우트)를 고르는 별도 윈도우.
/// "+ 추가"로 Strava에서 가져오고, "코스 만들기"로 변환 워크스페이스 윈도우를 연다.
struct RouteLibraryView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(RouteListViewModel.self) private var routeVM

    @State private var searchText = ""
    @State private var showingMyRoutes = false
    @State private var showingLogin = false
    @State private var showingLoginAlert = false

    private var filteredRoutes: [Route] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return routeVM.routes }
        return routeVM.routes.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("이름으로 검색", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    addTapped()
                } label: {
                    Label("추가", systemImage: "plus")
                }
                .help("내 경로에서 가져오기")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()
            content
        }
        .frame(minWidth: 360, idealWidth: 440, minHeight: 420, idealHeight: 600)
        .navigationTitle("코스로 만들 경로")
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
        .focusedSceneValue(\.addRouteAction, { addTapped() })
    }

    @ViewBuilder
    private var content: some View {
        if routeVM.routes.isEmpty {
            ContentUnavailableView {
                Label("경로 없음", systemImage: "bicycle")
            } description: {
                Text("+ 버튼으로 내 경로에서 가져오세요.")
            }
        } else if filteredRoutes.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                ForEach(filteredRoutes) { route in
                    RouteLibraryRow(route: route, progress: routeVM.progress(for: route.id)) {
                        openWindow(id: "route-workspace", value: route.id)
                        dismissWindow(id: "route-library")
                    }
                }
            }
        }
    }

    private func addTapped() {
        if AppSettings.cookie.isEmpty { showingLoginAlert = true }
        else { showingMyRoutes = true }
    }
}

private struct RouteLibraryRow: View {
    let route: Route
    let progress: ImportRouteUseCase.Progress?
    let onLoad: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RouteRow(route: route, progress: progress)
            Spacer()
            Button("코스 만들기", action: onLoad)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(route.status != .ready)
        }
        .padding(.vertical, 2)
    }
}
