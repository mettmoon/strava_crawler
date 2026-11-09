import SwiftUI
import Observation
import CourseBoyKit

/// Strava 내 라우트 페이징 로더.
@MainActor
@Observable
final class MyRoutesLoader {
    var routes: [MyRoute] = []
    var isLoading = false
    var hasMore = true
    var errorMessage: String?
    /// 마지막 실패가 인증 문제(세션 만료 등)라 다시 로그인해야 하는지.
    var needsLogin = false

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
        needsLogin = false
        defer { isLoading = false }
        do {
            try await fetchPage(retryOnAuthFailure: true)
        } catch {
            errorMessage = error.localizedDescription
            if case StravaError.notAuthenticated = error { needsLogin = true }
            hasMore = false
        }
    }

    /// 실패한 지점부터 다시 시도. 이미 받은 페이지는 유지한다.
    func retry() async {
        errorMessage = nil
        needsLogin = false
        hasMore = true
        await loadNext()
    }

    /// 로그인 계정이 바뀌었을 수 있으므로 처음부터 다시 받는다.
    func reset() {
        routes = []
        after = "0"
        hasMore = true
        errorMessage = nil
        needsLogin = false
        csrf = nil
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

/// Strava 경로 URL(또는 숫자 ID)로 경로를 가져오는 시트.
struct URLImportView: View {
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
        dismiss()
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
