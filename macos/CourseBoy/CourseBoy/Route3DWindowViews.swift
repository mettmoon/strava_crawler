import SwiftUI
import CourseBoyKit

/// 별도 윈도우에서 단일 경로(라우트)의 3D 뷰만 표시.
struct Route3DWindowView: View {
    var routeID: String?
    var container: AppContainer

    @Environment(RouteListViewModel.self) private var routeVM
    @State private var trackPoints: [TrackPoint] = []
    @State private var loadError: String?

    private var route: Route? {
        guard let id = routeID else { return nil }
        return routeVM.routes.first { $0.id == id }
    }

    var body: some View {
        Group {
            if let route {
                content(for: route)
                    .navigationTitle(route.title)
                    .navigationSubtitle("3D 경로")
            } else if routeID == nil {
                ContentUnavailableView("경로를 찾을 수 없음", systemImage: "bicycle")
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: routeID) {
            loadCourse()
        }
    }

    @ViewBuilder
    private func content(for route: Route) -> some View {
        if let loadError {
            ContentUnavailableView {
                Label("경로 데이터를 읽지 못함", systemImage: "exclamationmark.triangle")
            } description: {
                Text(loadError)
            }
        } else if trackPoints.isEmpty {
            ContentUnavailableView {
                Label("경로 데이터 없음", systemImage: "mountain.2")
            } description: {
                Text("경로가 처리되면 3D 뷰가 표시됩니다.")
            }
        } else {
            Route3DView(trackPoints: trackPoints)
        }
    }

    private func loadCourse() {
        loadError = nil
        guard let route, route.status == .ready, !route.tcxData.isEmpty else {
            trackPoints = []; return
        }
        do {
            let parsed = try TCXCourse(data: route.tcxData)
            trackPoints = parsed.trackPoints
        } catch {
            loadError = error.localizedDescription
            trackPoints = []
        }
    }
}

/// 별도 윈도우에서 단일 구간의 3D 뷰만 표시.
struct Segment3DWindowView: View {
    var segmentID: String?
    var container: AppContainer

    @State private var segment: SegmentInfo?

    var body: some View {
        Group {
            if let segment {
                let pts = trackPoints(for: segment)
                if pts.isEmpty {
                    ContentUnavailableView {
                        Label("경로 데이터 없음", systemImage: "mountain.2")
                    } description: {
                        Text("이 구간에 저장된 좌표 데이터가 없습니다.")
                    }
                } else {
                    Route3DView(trackPoints: pts)
                        .navigationTitle(segment.name)
                        .navigationSubtitle("3D 경로")
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
    }

    private func load() async {
        guard let id = segmentID else { segment = nil; return }
        segment = try? await container.segmentRepository.fetch(id: id)
    }
}
