import SwiftUI
import Observation
import StravaTCXKit

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
        return StravaClient(cookies: cookie.isEmpty ? [:] : ["_strava4_session": cookie])
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
            let token: String
            if let csrf { token = csrf } else {
                token = try await client.fetchCSRFToken()
                csrf = token
            }
            let page = try await client.fetchMyRoutes(after: after, pageSize: pageSize, csrfToken: token)
            routes.append(contentsOf: page.routes)
            after = page.nextAfter ?? String((Int(after) ?? 0) + pageSize)
            hasMore = page.hasMore && !page.routes.isEmpty
        } catch {
            errorMessage = error.localizedDescription
            hasMore = false
        }
    }
}

/// ‘내 경로에서 가져오기’ 시트 — 라우트 목록(페이징) → 선택.
struct MyRoutesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var loader = MyRoutesLoader()
    let onSelect: (MyRoute) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("내 경로").font(.headline)
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            content
        }
        .frame(width: 540, height: 620)
        .task { await loader.loadFirstPageIfNeeded() }
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
