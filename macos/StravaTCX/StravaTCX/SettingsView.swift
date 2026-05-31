import SwiftUI

/// 시스템 메뉴 ‘설정…’ (cmd+,) 화면. Strava 로그인/쿠키.
struct SettingsView: View {
    var body: some View {
        StravaSettingsView()
            .frame(width: 480, height: 360)
    }
}

private struct StravaSettingsView: View {
    @State private var cookie = AppSettings.cookie
    @State private var showingLogin = false
    @State private var segmentInterval = AppSettings.segmentRequestInterval

    var body: some View {
        Form {
            Section {
                HStack {
                    if cookie.isEmpty {
                        Label("로그인되지 않음", systemImage: "person.crop.circle.badge.xmark")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Strava 로그인…") { showingLogin = true }
                    } else {
                        Label("세션 저장됨", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Spacer()
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
                Stepper(value: $segmentInterval, in: 0...60, step: 1) {
                    HStack {
                        Text("세그먼트 요청 간격")
                        Spacer()
                        Text("\(Int(segmentInterval))초")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("크롤링")
            } footer: {
                Text("세그먼트 정보를 가져올 때 요청 사이의 대기 시간입니다. 값이 작으면 429(요청 과다) 오류가 발생할 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .onChange(of: segmentInterval) { _, newValue in
            AppSettings.segmentRequestInterval = newValue
        }
        .sheet(isPresented: $showingLogin) {
            StravaLoginView { value, csrf in
                if let csrf { AppSettings.csrfToken = csrf }
                cookie = value   // onChange → Keychain 저장
            }
        }
    }
}
