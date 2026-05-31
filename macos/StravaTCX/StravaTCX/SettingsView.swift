import SwiftUI

/// 시스템 메뉴 ‘설정…’ (cmd+,) 화면. 데모 모드 + Strava 쿠키.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("일반", systemImage: "gearshape") }
            StravaSettingsView()
                .tabItem { Label("Strava", systemImage: "person.badge.key") }
        }
        .frame(width: 480, height: 280)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(AppSettings.demoModeKey) private var demoMode = true

    var body: some View {
        Form {
            Toggle("데모 모드 (샘플 데이터)", isOn: $demoMode)
            Text("켜면 네트워크 없이 합성 샘플 데이터로 전체 흐름을 시연합니다. 끄면 실제 Strava 에서 가져옵니다.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
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
        }
        .sheet(isPresented: $showingLogin) {
            StravaLoginView { value in
                cookie = value   // onChange → Keychain 저장
            }
        }
    }
}
