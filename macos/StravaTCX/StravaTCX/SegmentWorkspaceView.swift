import SwiftUI
import StravaTCXKit

/// 별도 윈도우에서 단일 구간을 보여주는 워크스페이스.
/// 좌측 사이드바 없이, 가운데 지도/3D 탭 + 우측 SegmentDetailView 인스펙터로 구성된다.
struct SegmentWorkspaceView: View {
    var segmentID: String?
    var container: AppContainer

    @State private var segment: SegmentInfo?
    @State private var highlightPoints: [TrackPoint] = []
    @State private var hoverInfo: RouteHoverInfo?

    var body: some View {
        Group {
            if let segment {
                workspace(for: segment)
                    .navigationTitle(segment.name)
                    .navigationSubtitle("구간")
            } else if segmentID == nil {
                ContentUnavailableView("구간을 찾을 수 없음", systemImage: "mountain.2")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: segmentID) {
            await load()
        }
    }

    @ViewBuilder
    private func workspace(for segment: SegmentInfo) -> some View {
        let pts = trackPoints(for: segment)
        contentPane(trackPoints: pts)
            .inspector(isPresented: .constant(true)) {
                SegmentDetailView(segment: segment) { highlights in
                    highlightPoints = highlights
                }
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
            }
    }

    @ViewBuilder
    private func contentPane(trackPoints pts: [TrackPoint]) -> some View {
        if pts.isEmpty {
            ContentUnavailableView {
                Label("경로 데이터 없음", systemImage: "map")
            } description: {
                Text("이 구간에 저장된 좌표 데이터가 없습니다.")
            }
        } else {
            TabView {
                Tab("지도", systemImage: "map.fill") {
                    VStack(spacing: 0) {
                        RouteMapView(
                            trackPoints: pts,
                            highlightPoints: highlightPoints,
                            cuePoints: [],
                            hoverInfo: $hoverInfo
                        )
                        Divider()
                        ElevationChartView(
                            trackPoints: pts,
                            markers: [],
                            hoverInfo: $hoverInfo
                        )
                    }
                }
                Tab("3D 경로", systemImage: "mountain.2.fill") {
                    Route3DView(trackPoints: pts, highlightPoints: highlightPoints)
                }
            }
            .tabViewStyle(.tabBarOnly)
        }
    }

    private func load() async {
        guard let id = segmentID else { segment = nil; return }
        segment = try? await container.segmentRepository.fetch(id: id)
    }
}
