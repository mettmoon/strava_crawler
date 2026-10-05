import CoursePreviewCore
import SwiftUI
import UniformTypeIdentifiers

struct FilePreviewHomeView: View {
    @State private var loadedCourse: LoadedCourse?
    @State private var fileError: FilePreviewError?
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if let loadedCourse {
                // 내비게이션 스택은 화면 크기에 따라 배치를 고르는 뷰어가 직접 둔다.
                CourseViewerView(course: loadedCourse) {
                    self.loadedCourse = nil
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
        // Files 앱 등에서 GPX·TCX 파일을 끌어다 놓으면 이 창에서 연다.
        .dropDestination(for: DroppedCourseFile.self) { files, _ in
            guard let file = files.first else { return false }
            switch file.result {
            case .success(let course):
                loadedCourse = course
            case .failure(let message):
                fileError = FilePreviewError(message: message)
            }
            return true
        } isTargeted: { isTargeted in
            withAnimation(.easeInOut(duration: 0.15)) {
                isDropTargeted = isTargeted
            }
        }
        .overlay {
            if isDropTargeted {
                CourseDropTargetOverlay()
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

/// 끌어다 놓은 코스 파일. 받은 임시 파일은 가져오기 클로저가 끝나면 지워지므로 그 안에서 바로 읽는다.
private struct DroppedCourseFile: Transferable {
    enum LoadResult {
        case success(LoadedCourse)
        case failure(String)
    }

    var result: LoadResult

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .courseBoyTCX) { received in
            DroppedCourseFile(file: received.file)
        }
        FileRepresentation(importedContentType: .courseBoyGPX) { received in
            DroppedCourseFile(file: received.file)
        }
    }

    init(file: URL) {
        do {
            result = .success(try RouteFileLoader.load(from: file))
        } catch {
            result = .failure(error.localizedDescription)
        }
    }
}

private struct CourseDropTargetOverlay: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(Color.accentColor.opacity(0.08))
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
            Label("놓으면 코스를 엽니다", systemImage: "arrow.down.doc")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .floatingCapsuleBackground()
        }
        .padding(12)
        .allowsHitTesting(false)
        .transition(.opacity)
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
