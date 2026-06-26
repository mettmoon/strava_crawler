import SwiftUI
import UniformTypeIdentifiers

struct FilePreviewHomeView: View {
    @Binding var loadedCourse: LoadedCourse?

    @State private var fileError: FilePreviewError?

    var body: some View {
        Group {
            if let loadedCourse {
                NavigationStack {
                    CourseViewerView(course: loadedCourse)
                        .navigationTitle(loadedCourse.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                browserButton
                            }
                        }
                }
            } else {
                CourseDocumentBrowserView(
                    onOpenFile: openFile,
                    onError: { message in
                        fileError = FilePreviewError(message: message)
                    }
                )
                .ignoresSafeArea()
            }
        }
        .alert(item: $fileError) { error in
            Alert(
                title: Text("파일을 열 수 없습니다"),
                message: Text(error.message),
                dismissButton: .default(Text("확인"))
            )
        }
        .onOpenURL { url in
            openFile(url)
        }
    }

    private var browserButton: some View {
        Button {
            loadedCourse = nil
        } label: {
            Image(systemName: "chevron.backward")
                .font(.body.weight(.semibold))
        }
        .accessibilityLabel("파일 브라우저로 돌아가기")
    }

    private func openFile(_ url: URL) {
        guard ["gpx", "tcx"].contains(url.pathExtension.lowercased()) else {
            fileError = FilePreviewError(message: "TCX 또는 GPX 파일만 열 수 있습니다.")
            return
        }

        do {
            loadedCourse = try RouteFileLoader.load(from: url)
        } catch {
            fileError = FilePreviewError(message: error.localizedDescription)
        }
    }
}

struct FilePreviewError: Identifiable {
    let id = UUID()
    let message: String
}

extension UTType {
    static let courseBoyGPX = UTType(importedAs: "com.topografix.gpx", conformingTo: .xml)
    static let courseBoyTCX = UTType(importedAs: "com.garmin.tcx", conformingTo: .xml)
}
