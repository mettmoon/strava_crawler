import AppKit
import CoursePreviewCore
import Quartz
import SwiftUI

@MainActor
final class PreviewViewController: NSViewController, QLPreviewingController {
    private var hostingController: NSHostingController<AnyView>?
    private var requestID = UUID()

    override func loadView() {
        view = NSView()
        preferredContentSize = NSSize(width: 960, height: 720)
        show(AnyView(CoursePreviewLoadingView()))
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let currentRequestID = UUID()
        requestID = currentRequestID

        do {
            let course = try await Task.detached(priority: .userInitiated) {
                try RouteFileLoader.load(from: url)
            }.value
            try Task.checkCancellation()
            guard requestID == currentRequestID else { return }
            show(AnyView(CoursePreviewView(course: course)))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard requestID == currentRequestID else { return }
            show(AnyView(CoursePreviewErrorView(message: error.localizedDescription)))
        }
    }

    private func show(_ rootView: AnyView) {
        if let hostingController {
            hostingController.view.removeFromSuperview()
            hostingController.removeFromParent()
        }

        let hostingController = NSHostingController(rootView: rootView)
        addChild(hostingController)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.hostingController = hostingController
    }
}

private struct CoursePreviewLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("코스를 불러오는 중…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CoursePreviewErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("미리보기를 표시할 수 없습니다", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
