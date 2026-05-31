import SwiftUI

/// 앱 최상위 탭 — ‘경로’(저장된 라우트)와 ‘구간’(다운로드한 세그먼트).
struct MainTabView: View {
    var body: some View {
        TabView {
            RouteListView()
                .tabItem { Label("경로", systemImage: "bicycle") }
            SegmentListView()
                .tabItem { Label("구간", systemImage: "mountain.2") }
        }
    }
}
