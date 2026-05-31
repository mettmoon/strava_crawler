import SwiftUI
import WebKit

/// Strava 로그인 시트. WKWebView 로 로그인 후 _strava4_session 쿠키를 수확한다.
struct StravaLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var status = "Strava 에 로그인하세요"
    let onComplete: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("Strava 로그인").font(.headline)
                Spacer()
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("세션 가져오기") {
                    Task { await harvestFromDefaultStore() }
                }
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()

            StravaWebView(
                onSession: { value in finish(with: value) },
                onStatus: { status = $0 }
            )
        }
        .frame(width: 540, height: 700)
    }

    private func finish(with cookie: String) {
        status = "세션 수집 완료"
        onComplete(cookie)
        dismiss()
    }

    /// 자동 감지가 안 될 때를 위한 수동 수확 (기본 데이터 스토어에서 직접 읽음).
    @MainActor
    private func harvestFromDefaultStore() async {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        if let session = cookies.first(where: { $0.name == "_strava4_session" })?.value,
           !session.isEmpty {
            finish(with: session)
        } else {
            status = "세션을 찾지 못했습니다. 로그인 후 다시 시도하세요."
        }
    }
}

/// Strava 로그인 페이지를 표시하고, 로그인 완료를 감지해 세션 쿠키를 콜백한다.
struct StravaWebView: NSViewRepresentable {
    let onSession: (String) -> Void
    let onStatus: (String) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()   // 영속 스토어(수동 수확과 공유)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://www.strava.com/login")!))
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: StravaWebView
        private var done = false

        init(_ parent: StravaWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !done, let url = webView.url else { return }
            let host = url.host ?? ""
            let path = url.path
            guard host.contains("strava.com") else { return }

            // 로그인 후 dashboard/onboarding/홈 으로 이동하면 인증된 세션으로 간주
            if path.hasPrefix("/dashboard") || path.hasPrefix("/onboarding") || path == "/" {
                harvest(webView)
            } else if path.contains("/login") {
                parent.onStatus("로그인하면 자동으로 세션을 가져옵니다")
            }
        }

        private func harvest(_ webView: WKWebView) {
            Task { @MainActor in
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                guard let session = cookies.first(where: { $0.name == "_strava4_session" })?.value,
                      !session.isEmpty else { return }
                done = true
                parent.onSession(session)
            }
        }
    }
}
