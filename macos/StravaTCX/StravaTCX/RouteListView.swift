import SwiftUI
import SwiftData

/// 앱 첫 화면 — 저장된 라우트 목록 + ‘추가하기’(→ 내 경로 목록).
struct RouteListView: View {
    @Environment(\.modelContext) private var context
    @Environment(ImportCoordinator.self) private var coordinator
    @Query(sort: \RouteRecord.createdAt, order: .reverse) private var routes: [RouteRecord]
    @State private var selection: RouteRecord?
    @State private var showingMyRoutes = false
    @State private var showingLogin = false
    @State private var showingLoginAlert = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(routes) { route in
                    RouteRow(route: route)
                        .tag(route)
                        .selectionDisabled(route.status == .processing)
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("라우트")
            .frame(minWidth: 240)
            .overlay {
                if routes.isEmpty {
                    ContentUnavailableView(
                        "저장된 라우트 없음",
                        systemImage: "tray",
                        description: Text("‘추가하기’ 로 내 경로에서 가져오세요.")
                    )
                }
            }
            .toolbar {
                ToolbarItem {
                    Button { addTapped() } label: {
                        Label("추가하기", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let selection {
                RouteDetailView(record: selection)
            } else {
                ContentUnavailableView(
                    "라우트를 선택하세요",
                    systemImage: "bicycle",
                    description: Text("왼쪽 목록에서 라우트를 고르거나 ‘추가하기’ 로 새로 가져오세요.")
                )
            }
        }
        .task { coordinator.reconcileOnLaunch(context: context) }
        .sheet(isPresented: $showingMyRoutes) {
            MyRoutesView { route in
                coordinator.importRoute(route, into: context)
            }
        }
        .sheet(isPresented: $showingLogin, onDismiss: {
            // 로그인 성공(쿠키 확보) 시 자동으로 내 경로 목록으로 이어감
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

    private func addTapped() {
        if AppSettings.cookie.isEmpty {
            showingLoginAlert = true
        } else {
            showingMyRoutes = true
        }
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets {
            context.delete(routes[index])
        }
    }
}

struct RouteRow: View {
    @Environment(ImportCoordinator.self) private var coordinator
    let route: RouteRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(route.title).fontWeight(.medium).lineLimit(1)
            switch route.status {
            case .processing:
                let p = coordinator.progress(for: route)
                HStack(spacing: 6) {
                    if let fraction = p?.fraction {
                        ProgressView(value: fraction).frame(maxWidth: 120)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    Text(p?.message ?? "처리 중…")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            case .failed:
                Label(route.errorMessage ?? "처리 실패", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).lineLimit(1)
            case .ready:
                Text("\(route.coursePointCount) CoursePoint · \(route.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
