import SwiftUI
import CourseBoyKit

/// 별도 윈도우에서 단일 구간을 보여주는 워크스페이스.
/// 좌측 사이드바 없이, 가운데 지도 + 우측 SegmentDetailView 인스펙터로 구성된다.
/// 3D 경로는 툴바의 버튼으로 별도 윈도우에서 띄운다.
struct SegmentWorkspaceView: View {
    var segmentID: String?
    var container: AppContainer

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var segment: SegmentInfo?
    @State private var highlightPoints: [TrackPoint] = []
    @State private var hoverInfo: RouteHoverInfo?
    @State private var showDeleteConfirm = false
    @State private var rangeSelection: ChartRangeSelection?
    @State private var pinnedDistanceKm: Double?

    var body: some View {
        Group {
            if let segment {
                workspace(for: segment)
                    .navigationTitle(segment.name)
                    .navigationSubtitle("구간")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                openWindow(id: "segment-3d", value: segment.segmentID)
                            } label: {
                                Label("3D 경로", systemImage: "view.3d")
                            }
                            .help("3D 경로를 별도 창에서 열기")
                        }
                    }
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
        .focusedSceneValue(\.segmentCommandHandler, {
            guard let id = segment?.segmentID else { return nil }
            return SegmentCommandHandler(
                reload: { await reloadSegment(id: id) },
                delete: { await MainActor.run { showDeleteConfirm = true } }
            )
        }())
        .confirmationDialog(
            "이 구간을 삭제하시겠습니까?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("삭제", role: .destructive) {
                guard let id = segment?.segmentID else { return }
                Task {
                    try? await container.deleteSegmentUseCase.execute(segmentID: id)
                    await MainActor.run {
                        dismiss()
                        NSApp.keyWindow?.close()
                    }
                }
            }
        } message: {
            Text("저장된 구간 데이터와 경로에서의 참조가 모두 제거됩니다.")
        }
    }

    @ViewBuilder
    private func workspace(for segment: SegmentInfo) -> some View {
        let pts = trackPoints(for: segment)
        contentPane(trackPoints: pts)
            .inspector(isPresented: .constant(true)) {
                ZStack {
                    SegmentDetailView(segment: segment) { highlights in
                        highlightPoints = highlights
                    }
                    .opacity(rangeSelection == nil ? 1 : 0)
                    .allowsHitTesting(rangeSelection == nil)

                    if let range = rangeSelection {
                        RangeStatsInspectorView(trackPoints: pts, range: range)
                            .background(.background)
                    }
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
            VStack(spacing: 0) {
                RouteMapView(
                    trackPoints: pts,
                    highlightPoints: highlightPoints,
                    cuePoints: [],
                    hoverInfo: $hoverInfo,
                    rangeSelection: rangeSelection,
                    pinnedDistanceKm: pinnedDistanceKm
                )
                Divider()
                ElevationChartView(
                    trackPoints: pts,
                    markers: [],
                    hoverInfo: $hoverInfo,
                    rangeSelection: $rangeSelection,
                    pinnedDistanceKm: $pinnedDistanceKm
                )
            }
        }
    }

    private func load() async {
        guard let id = segmentID else { segment = nil; return }
        segment = try? await container.segmentRepository.fetch(id: id)
        pinnedDistanceKm = nil
        rangeSelection = nil
    }

    private func reloadSegment(id: String) async {
        try? await container.reloadSegmentUseCase.execute(segmentID: id)
        segment = try? await container.segmentRepository.fetch(id: id)
    }
}
