import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CourseDocumentBrowserView: UIViewControllerRepresentable {
    var onOpenFile: (URL) -> Void
    var onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOpenFile: onOpenFile, onError: onError)
    }

    func makeUIViewController(context: Context) -> UIDocumentBrowserViewController {
        let browser = UIDocumentBrowserViewController(forOpening: [.courseBoyGPX, .courseBoyTCX])
        browser.delegate = context.coordinator
        browser.allowsDocumentCreation = false
        browser.allowsPickingMultipleItems = false
        browser.shouldShowFileExtensions = true
        browser.title = "CourseBoy"
        return browser
    }

    func updateUIViewController(_ uiViewController: UIDocumentBrowserViewController, context: Context) {
        context.coordinator.onOpenFile = onOpenFile
        context.coordinator.onError = onError
    }

    final class Coordinator: NSObject, UIDocumentBrowserViewControllerDelegate {
        var onOpenFile: (URL) -> Void
        var onError: (String) -> Void

        init(onOpenFile: @escaping (URL) -> Void, onError: @escaping (String) -> Void) {
            self.onOpenFile = onOpenFile
            self.onError = onError
        }

        func documentBrowser(
            _ controller: UIDocumentBrowserViewController,
            didPickDocumentsAt documentURLs: [URL]
        ) {
            guard let url = documentURLs.first else {
                onError("선택한 파일을 찾을 수 없습니다.")
                return
            }
            onOpenFile(url)
        }

        func documentBrowser(
            _ controller: UIDocumentBrowserViewController,
            didImportDocumentAt sourceURL: URL,
            toDestinationURL destinationURL: URL
        ) {
            onOpenFile(destinationURL)
        }

        func documentBrowser(
            _ controller: UIDocumentBrowserViewController,
            failedToImportDocumentAt documentURL: URL,
            error: Error?
        ) {
            onError(error?.localizedDescription ?? "파일을 가져올 수 없습니다.")
        }
    }
}
