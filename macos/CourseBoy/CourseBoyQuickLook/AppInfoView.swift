import SwiftUI

/// 메뉴의 '설정'이 여는 시트. 지금은 앱 정보와 버전만 보여준다.
struct AppInfoView: View {
    @Environment(\.dismiss) private var dismiss

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 10) {
                        Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 72, height: 72)
                            .background(
                                LinearGradient(
                                    colors: [HomePalette.backgroundTop, HomePalette.prominentFill],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                        Text("CourseBoy")
                            .font(.title2.weight(.bold))
                        Text("GPX·TCX 코스를 지도와 고도, 큐시트로 확인합니다.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .listRowBackground(Color.clear)
                }

                Section("앱 정보") {
                    LabeledContent("버전", value: version)
                    LabeledContent("빌드", value: build)
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기", systemImage: "xmark") {
                        dismiss()
                    }
                }
            }
        }
    }
}
