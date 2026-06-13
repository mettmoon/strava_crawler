import SwiftUI
import Observation
import CourseBoyKit

/// 내 라우트 페이징 로더.
@MainActor
@Observable
final class MyRoutesLoader {
    var routes: [MyRoute] = []
    var isLoading = false
    var hasMore = true
    var errorMessage: String?

    private var after = "0"
    private let pageSize = 16
    private var csrf: String?

    private var client: StravaClient {
        let cookie = AppSettings.cookie
        let token = AppSettings.csrfToken
        return StravaClient(
            cookies: cookie.isEmpty ? [:] : ["_strava4_session": cookie],
            csrfToken: token.isEmpty ? nil : token
        )
    }

    func loadFirstPageIfNeeded() async {
        if routes.isEmpty && errorMessage == nil { await loadNext() }
    }

    func loadNext() async {
        guard !isLoading, hasMore else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await fetchPage(retryOnAuthFailure: true)
        } catch {
            errorMessage = error.localizedDescription
            hasMore = false
        }
    }

    /// 한 페이지를 가져온다. CSRF 만료(notAuthenticated)면 토큰을 재수확해 1회 재시도.
    private func fetchPage(retryOnAuthFailure: Bool) async throws {
        let token = try await resolveToken()
        do {
            let page = try await client.fetchMyRoutes(after: after, pageSize: pageSize, csrfToken: token)
            routes.append(contentsOf: page.routes)
            after = page.nextAfter ?? String((Int(after) ?? 0) + pageSize)
            hasMore = page.hasMore && !page.routes.isEmpty
        } catch StravaError.notAuthenticated where retryOnAuthFailure {
            // 캐시·저장된 CSRF 가 만료됐을 수 있다. 폐기 후 페이지에서 재수확해 1회 재시도.
            // (세션 자체가 만료됐다면 resolveToken 이 다시 notAuthenticated 를 던져 사용자에게 전달된다.)
            csrf = nil
            AppSettings.csrfToken = ""
            try await fetchPage(retryOnAuthFailure: false)
        }
    }

    /// 사용할 CSRF 토큰 확보: 캐시 → 저장값 → 페이지 수확 순. 수확 시 저장값도 갱신.
    private func resolveToken() async throws -> String {
        if let csrf { return csrf }
        let stored = AppSettings.csrfToken
        if !stored.isEmpty {
            csrf = stored
            return stored
        }
        let harvested = try await client.fetchCSRFToken()
        csrf = harvested
        AppSettings.csrfToken = harvested
        return harvested
    }
}

/// ‘내 경로에서 가져오기’ 시트 — 라우트 목록(페이징) → 선택.
struct MyRoutesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var loader = MyRoutesLoader()
    @State private var showURLImport = false
    let onSelect: (MyRoute) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("내 경로").font(.headline)
                Spacer()
                Button("URL로 가져오기") { showURLImport = true }
                    .buttonStyle(.bordered)
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            content
        }
        .frame(width: 540, height: 620)
        .task { await loader.loadFirstPageIfNeeded() }
        .sheet(isPresented: $showURLImport) {
            URLImportView { route in
                onSelect(route)
                dismiss()
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let error = loader.errorMessage, loader.routes.isEmpty {
            ContentUnavailableView {
                Label("불러오기 실패", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("다시 시도") {
                    loader.errorMessage = nil
                    loader.hasMore = true
                    Task { await loader.loadNext() }
                }
            }
        } else if loader.routes.isEmpty && loader.isLoading {
            ProgressView("불러오는 중…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(loader.routes) { route in
                    Button {
                        onSelect(route)
                        dismiss()
                    } label: {
                        MyRouteRow(route: route)
                    }
                    .buttonStyle(.plain)
                }
                if loader.hasMore {
                    HStack {
                        Spacer()
                        if loader.isLoading {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("더 보기") { Task { await loader.loadNext() } }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct URLImportView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var errorMessage: String?
    let onSelect: (MyRoute) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("URL로 가져오기").font(.headline)
            Text("Strava 경로 URL을 붙여넣으세요.")
                .foregroundStyle(.secondary)
                .font(.subheadline)
            TextField("https://www.strava.com/routes/3495269006478904270", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            if let error = errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("가져오기") { submit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func submit() {
        errorMessage = nil
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard let routeID = extractRouteID(from: trimmed) else {
            errorMessage = "유효한 Strava 경로 URL이 아닙니다."
            return
        }
        onSelect(MyRoute(id: routeID, name: "Route \(routeID)"))
    }

    /// https://www.strava.com/routes/<id> 또는 숫자 ID 직접 입력 지원.
    private func extractRouteID(from text: String) -> String? {
        // 숫자만 입력한 경우
        if text.allSatisfy(\.isNumber), !text.isEmpty { return text }
        // URL 경로에서 추출: /routes/<id>
        guard let url = URL(string: text) else { return nil }
        let components = url.pathComponents
        if let idx = components.firstIndex(of: "routes"), idx + 1 < components.count {
            let id = components[idx + 1]
            if id.allSatisfy(\.isNumber), !id.isEmpty { return id }
        }
        return nil
    }
}

private struct MyRouteRow: View {
    let route: MyRoute

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
            VStack(alignment: .leading, spacing: 3) {
                Text(route.name).fontWeight(.medium).lineLimit(1)
                HStack(spacing: 8) {
                    if let d = route.distanceText {
                        Label(d, systemImage: "ruler").labelStyle(.titleAndIcon)
                    }
                    if let e = route.elevationText {
                        Label(e, systemImage: "mountain.2").labelStyle(.titleAndIcon)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("ID \(route.id)").font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var thumbnail: some View {
        if let url = route.thumbnailURL {
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
