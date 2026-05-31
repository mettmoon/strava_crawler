import SwiftUI

/// 시스템 메뉴 ‘설정…’ (cmd+,) 화면. Strava 로그인/쿠키.
struct SettingsView: View {
    var body: some View {
        StravaSettingsView()
            .frame(width: 480, height: 300)
    }
}

private struct StravaSettingsView: View {
    @State private var cookie = AppSettings.cookie
    @State private var showingLogin = false

    var body: some View {
        Form {
            Section {
                HStack {
                    if cookie.isEmpty {
                        Label("로그인되지 않음", systemImage: "person.crop.circle.badge.xmark")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("세션 저장됨", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                    Spacer()
                    Button("Strava 로그인…") { showingLogin = true }
                    if !cookie.isEmpty {
                        Button("로그아웃") { cookie = "" }
                    }
                }
            } header: {
                Text("로그인")
            } footer: {
                Text("로그인하면 세션 쿠키가 자동으로 수집되어 Keychain 에 저장됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                SecureField("_strava4_session 값", text: $cookie)
                Text("로그인 버튼으로 자동 입력되거나, 직접 붙여넣을 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("세션 쿠키 (수동)")
            }
        }
        .formStyle(.grouped)
        .onChange(of: cookie) { _, newValue in
            AppSettings.cookie = newValue
            // 로그아웃(쿠키 비움) 시 CSRF 토큰도 함께 폐기.
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                AppSettings.csrfToken = ""
            }
        }
        .sheet(isPresented: $showingLogin) {
            StravaLoginView { value, csrf in
                if let csrf { AppSettings.csrfToken = csrf }
                cookie = value   // onChange → Keychain 저장
            }
        }
    }
}
