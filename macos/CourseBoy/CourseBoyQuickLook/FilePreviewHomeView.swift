import SwiftUI
import UniformTypeIdentifiers

struct FilePreviewHomeView: View {
    @Binding var loadedCourse: LoadedCourse?

    @State private var isFileImporterPresented = false
    @State private var fileError: FilePreviewError?

    var body: some View {
        NavigationStack {
            Group {
                if let loadedCourse {
                    CourseViewerView(course: loadedCourse) {
                        isFileImporterPresented = true
                    }
                } else {
                    emptyState
                }
            }
            .navigationTitle(loadedCourse?.title ?? "CourseBoy")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isFileImporterPresented = true
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("파일 열기")
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.courseBoyGPX, .courseBoyTCX],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    openFile(urls.first)
                case .failure(let error):
                    fileError = FilePreviewError(message: error.localizedDescription)
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
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 64, weight: .regular))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("CourseBoy")
                    .font(.largeTitle.weight(.semibold))
                Text("TCX 또는 GPX 코스를 열어 경로, 고도, 큐시트를 확인합니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Button {
                isFileImporterPresented = true
            } label: {
                Label("파일 열기", systemImage: "folder")
                    .font(.headline)
                    .frame(maxWidth: 260)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func openFile(_ url: URL?) {
        guard let url else {
            fileError = FilePreviewError(message: "선택한 파일을 찾을 수 없습니다.")
            return
        }

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
