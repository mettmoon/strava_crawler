import AppKit
import CoursePreviewCore
import SwiftUI

/// Quick Look 샌드박스 안에서는 MKMapView가 타일을 불러오지 못하므로,
/// 확장에 포함된 XPC 서비스에서 렌더링한 지도 스냅샷을 보여준다.
struct CoursePreviewMapSnapshotView: View {
    let course: LoadedCourse

    @Environment(\.colorScheme) private var colorScheme
    @State private var image: NSImage?
    @State private var errorMessage: String?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                        .overlay(alignment: .bottomLeading) {
                            MapAttributionView()
                        }
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                } else {
                    ProgressView()
                }
            }
            .task(id: SnapshotKey(size: proxy.size, isDark: colorScheme == .dark, courseID: course.id)) {
                await loadSnapshot(size: proxy.size, isDark: colorScheme == .dark)
            }
        }
    }

    private func loadSnapshot(size: CGSize, isDark: Bool) async {
        guard size.width > 1, size.height > 1 else { return }
        // 창 크기를 조절하는 동안 요청이 몰리지 않도록 잠깐 기다린다.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }

        let request = MapSnapshotRequest(
            coordinates: course.trackPoints.map { [$0.coordinate.latitude, $0.coordinate.longitude] },
            markers: markers(),
            width: size.width,
            height: size.height,
            isDark: isDark
        )
        do {
            let data = try await MapSnapshotClient.snapshot(request)
            guard !Task.isCancelled else { return }
            image = NSImage(data: data)
            errorMessage = image == nil ? "지도 이미지를 읽지 못했습니다." : nil
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func markers() -> [MapSnapshotRequest.Marker] {
        var markers = course.sortedCuePoints.map {
            MapSnapshotRequest.Marker(
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude,
                kind: .cue,
                pointType: $0.pointType
            )
        }
        if let first = course.trackPoints.first {
            markers.append(MapSnapshotRequest.Marker(
                latitude: first.coordinate.latitude,
                longitude: first.coordinate.longitude,
                kind: .start,
                pointType: nil
            ))
        }
        if course.trackPoints.count > 1, let last = course.trackPoints.last {
            markers.append(MapSnapshotRequest.Marker(
                latitude: last.coordinate.latitude,
                longitude: last.coordinate.longitude,
                kind: .end,
                pointType: nil
            ))
        }
        return markers
    }
}

/// 스냅샷 이미지에는 MKMapView가 그려주던 Apple 지도 로고와 법적 정보 링크가 없어 직접 표시한다.
private struct MapAttributionView: View {
    var body: some View {
        HStack(spacing: 8) {
            Label("지도", systemImage: "applelogo")
                .font(.caption.weight(.semibold))
            Link("법적 정보", destination: URL(string: "https://www.apple.com/legal/internet-services/maps/")!)
                .font(.caption2)
                .underline()
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.6), radius: 1)
        .padding(10)
    }
}

private struct SnapshotKey: Equatable {
    let size: CGSize
    let isDark: Bool
    let courseID: UUID
}

private enum MapSnapshotClient {
    struct ServiceError: LocalizedError {
        let errorDescription: String?
    }

    static func snapshot(_ request: MapSnapshotRequest) async throws -> Data {
        let requestData = try JSONEncoder().encode(request)
        let connection = NSXPCConnection(serviceName: MapSnapshotService.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: MapSnapshotServiceProtocol.self)
        connection.resume()
        defer { connection.invalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(with: .failure(error))
            } as? MapSnapshotServiceProtocol
            guard let proxy else {
                once.resume(with: .failure(ServiceError(errorDescription: "지도 서비스에 연결하지 못했습니다.")))
                return
            }
            proxy.makeSnapshot(requestData: requestData) { data, message in
                if let data {
                    once.resume(with: .success(data))
                } else {
                    once.resume(with: .failure(ServiceError(errorDescription: message ?? "지도를 그리지 못했습니다.")))
                }
            }
        }
    }
}

/// XPC 응답과 연결 오류 핸들러가 모두 불려도 continuation은 한 번만 재개한다.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Data, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
