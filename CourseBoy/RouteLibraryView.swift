import SwiftUI
import CourseBoyKit

/// 목록의 한 행: Strava 내 경로(remote)와 다운로드한 경로(local)를 경로 ID 로 합친 것.
/// - remote 만 있음: 아직 다운로드하지 않은 Strava 내 경로
/// - local 만 있음: URL 로 가져왔거나 아직 불러오지 않은 페이지에 있는 경로
struct RouteLibraryItem: Identifiable {
    let id: String
    var remote: MyRoute?
    var local: Route?

    var title: String { remote?.name ?? local?.title ?? "Route \(id)" }
    var stravaURL: URL { URL(string: "https://www.strava.com/routes/\(id)")! }
}

/// 코스로 만들 경로를 고르는 별도 윈도우.
/// Strava 내 경로와 다운로드한 경로를 한 목록으로 보여주고, 행 버튼은 상태에 따라
/// "다운로드" → (구간 정보 수집 중) → "코스 만들기"로 바뀐다.
struct RouteLibraryView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openURL) private var openURL
    @Environment(RouteListViewModel.self) private var routeVM

    @State private var loader = MyRoutesLoader()
    @State private var searchText = ""
    @State private var isLoggedIn = !AppSettings.cookie.isEmpty
    @State private var showingURLImport = false
    @State private var showingLogin = false
    @State private var pendingDelete: RouteLibraryItem?

    /// 내 경로 목록에 없는 다운로드 경로(최근 다운로드 순)를 위에, 그 아래 Strava 내 경로 순서대로.
    private var items: [RouteLibraryItem] {
        var localByID: [String: Route] = [:]
        for route in routeVM.routes where localByID[route.id] == nil { localByID[route.id] = route }

        var seen = Set<String>()
        var remoteItems: [RouteLibraryItem] = []
        for route in loader.routes where seen.insert(route.id).inserted {
            remoteItems.append(RouteLibraryItem(id: route.id, remote: route, local: localByID[route.id]))
        }
        var localOnly: [RouteLibraryItem] = []
        for route in routeVM.routes where seen.insert(route.id).inserted {
            localOnly.append(RouteLibraryItem(id: route.id, remote: nil, local: route))
        }
        return localOnly + remoteItems
    }

    private func filtered(_ items: [RouteLibraryItem]) -> [RouteLibraryItem] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { $0.title.lowercased().contains(q) }
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
                    showingURLImport = true
                } label: {
                    Label("URL로 가져오기", systemImage: "link")
                }
                .help("Strava 경로 URL로 가져오기")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()
            content
        }
        .frame(minWidth: 440, idealWidth: 520, minHeight: 420, idealHeight: 640)
        .navigationTitle("코스로 만들 경로")
        .task { await routeVM.reconcile() }
        .task { await routeVM.load() }
        .task {
            if isLoggedIn { await loader.loadFirstPageIfNeeded() }
        }
        .sheet(isPresented: $showingURLImport) {
            URLImportView { download($0) }
        }
        .sheet(isPresented: $showingLogin, onDismiss: loginDismissed) {
            StravaLoginView { value, csrf in
                AppSettings.cookie = value
                if let csrf { AppSettings.csrfToken = csrf }
            }
        }
        .confirmationDialog(
            "'\(pendingDelete?.title ?? "")'의 다운로드 데이터를 삭제할까요?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { item in
            Button("삭제", role: .destructive) {
                Task { await routeVM.delete(routeID: item.id) }
            }
        } message: { item in
            if item.remote == nil {
                Text("TCX와 구간 정보가 삭제되고 목록에서 사라집니다. 이미 만든 코스는 그대로 남습니다.")
            } else {
                Text("TCX와 구간 정보가 삭제됩니다. 다시 다운로드할 수 있고, 이미 만든 코스는 그대로 남습니다.")
            }
        }
        .focusedSceneValue(\.addRouteAction, { showingURLImport = true })
    }

    // MARK: - 목록

    @ViewBuilder
    private var content: some View {
        let all = items
        let shown = filtered(all)
        if all.isEmpty {
            emptyState
        } else if shown.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                ForEach(shown) { item in
                    RouteLibraryRow(
                        item: item,
                        progress: routeVM.progress(for: item.id),
                        onDownload: { download(item) },
                        onRetry: { routeVM.retry(routeID: item.id) },
                        onMakeCourse: { makeCourse(item) }
                    )
                    .contextMenu { contextMenu(for: item) }
                }
                footer
            }
        }
    }

    /// 목록 맨 아래: 로그인 안내 / 불러오기 실패 / 로딩 / 더 보기.
    @ViewBuilder
    private var footer: some View {
        if !isLoggedIn {
            FooterNotice(systemImage: "info.circle", text: "Strava에 로그인하면 내 경로를 모두 볼 수 있어요.") {
                Button("로그인") { showingLogin = true }
            }
        } else if let error = loader.errorMessage {
            FooterNotice(systemImage: "exclamationmark.triangle", text: error) {
                if loader.needsLogin { Button("로그인") { showingLogin = true } }
                Button("다시 시도") { Task { await loader.retry() } }
            }
        } else if loader.isLoading {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 4)
        } else if loader.hasMore {
            HStack {
                Spacer()
                Button("더 보기") { Task { await loader.loadNext() } }
                Spacer()
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !isLoggedIn {
            ContentUnavailableView {
                Label("경로 없음", systemImage: "bicycle")
            } description: {
                Text("Strava에 로그인하면 내 경로를 불러올 수 있어요.\nURL로 가져올 수도 있어요.")
            } actions: {
                Button("로그인") { showingLogin = true }
            }
        } else if let error = loader.errorMessage {
            ContentUnavailableView {
                Label("불러오기 실패", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                if loader.needsLogin { Button("로그인") { showingLogin = true } }
                Button("다시 시도") { Task { await loader.retry() } }
            }
        } else if loader.isLoading || loader.hasMore {
            ProgressView("불러오는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("경로 없음", systemImage: "bicycle")
            } description: {
                Text("Strava에 만든 경로가 없어요. URL로 가져올 수 있어요.")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for item: RouteLibraryItem) -> some View {
        if let local = item.local {
            if local.status != .processing {
                Button("다시 다운로드") { routeVM.retry(routeID: item.id) }
            }
        } else {
            Button("다운로드") { download(item) }
        }
        Button("Strava에서 열기") { openURL(item.stravaURL) }
        if let local = item.local, local.status != .processing {
            Divider()
            Button("다운로드 데이터 삭제…", role: .destructive) { pendingDelete = item }
        }
    }

    // MARK: - 동작

    private func download(_ item: RouteLibraryItem) {
        download(item.remote ?? MyRoute(id: item.id, name: item.title))
    }

    /// 이미 다운로드한 경로면 새로 추가하지 않고 다시 다운로드한다(목록 중복 방지).
    private func download(_ route: MyRoute) {
        if routeVM.routes.contains(where: { $0.id == route.id }) {
            routeVM.retry(routeID: route.id)
        } else {
            routeVM.importRoute(route)
        }
    }

    private func makeCourse(_ item: RouteLibraryItem) {
        openWindow(id: "route-workspace", value: item.id)
        dismissWindow(id: "route-library")
    }

    private func loginDismissed() {
        isLoggedIn = !AppSettings.cookie.isEmpty
        guard isLoggedIn else { return }
        loader.reset()
        Task { await loader.loadNext() }
    }
}

// MARK: - 행

private struct RouteLibraryRow: View {
    let item: RouteLibraryItem
    let progress: ImportRouteUseCase.Progress?
    let onDownload: () -> Void
    let onRetry: () -> Void
    let onMakeCourse: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).fontWeight(.medium).lineLimit(1)
                metrics
                status
            }
            Spacer(minLength: 8)
            action
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var metrics: some View {
        let distance = item.remote?.distanceText
        let elevation = item.remote?.elevationText
        if distance != nil || elevation != nil {
            HStack(spacing: 8) {
                if let distance { Label(distance, systemImage: "ruler") }
                if let elevation { Label(elevation, systemImage: "mountain.2") }
            }
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var status: some View {
        if let local = item.local {
            Group {
                switch local.status {
                case .processing:
                    HStack(spacing: 6) {
                        if let fraction = progress?.fraction {
                            ProgressView(value: fraction).frame(maxWidth: 100)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                        Text(progress?.message ?? "구간 정보 다운로드 중…").lineLimit(1)
                    }
                case .failed:
                    Label(local.errorMessage ?? "다운로드 실패", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                case .ready:
                    Text("구간 \(local.segments.count)개 · \(local.createdAt.formatted(.relative(presentation: .named))) 다운로드")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var action: some View {
        switch item.local?.status {
        case nil:
            Button("다운로드", action: onDownload)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .processing:
            EmptyView()
        case .failed:
            Button("다시 시도", action: onRetry)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .ready:
            Button("코스 만들기", action: onMakeCourse)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    @ViewBuilder private var thumbnail: some View {
        if let url = item.remote?.thumbnailURL {
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 70, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary)
                .frame(width: 70, height: 48)
                .overlay(Image(systemName: "map").foregroundStyle(.secondary))
        }
    }
}

/// 목록 하단 안내 줄 (아이콘 + 문구 + 버튼).
private struct FooterNotice<Actions: View>: View {
    let systemImage: String
    let text: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions()
                .controlSize(.small)
        }
        .padding(.vertical, 6)
    }
}
