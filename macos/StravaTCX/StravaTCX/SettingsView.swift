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

    var body: some View {
        Form {
            Section {
                SecureField("_strava4_session 값", text: $cookie)
                Text("브라우저 개발자도구 → Application → Cookies → strava.com 에서 복사")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Strava 세션 쿠키")
            } footer: {
                Text("Keychain 에 안전하게 저장됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: cookie) { _, newValue in
            AppSettings.cookie = newValue
        }
    }
}
