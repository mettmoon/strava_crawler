import SwiftUI

/// 메인 윈도우 — 환영 디스패치 화면.
/// 좌측 사이드바 없이, 사용자가 어디로 갈지 선택하는 진입점.
struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 8) {
                Image(systemName: "bicycle.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                Text("Strava TCX")
                    .font(.largeTitle.bold())
                Text("Strava 경로를 가져오고, 큐시트를 편집하고, 내보냅니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                DispatchButton(
                    title: "경로 불러오기",
                    subtitle: "Strava에서 가져온 경로 열기",
                    systemImage: "bicycle"
                ) { openWindow(id: "route-library") }

                DispatchButton(
                    title: "구간 불러오기",
                    subtitle: "저장된 구간 열기",
                    systemImage: "mountain.2"
                ) { openWindow(id: "segment-library") }

                DispatchButton(
                    title: "코스 불러오기",
                    subtitle: "코스 보기 또는 편집",
                    systemImage: "map"
                ) { openWindow(id: "course-library") }
            }
            .frame(maxWidth: 380)

            Spacer()
        }
        .padding(.top, 60)
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Strava TCX")
    }
}

private struct DispatchButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 36)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
