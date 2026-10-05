import CoursePreviewCore
import SwiftUI
import UniformTypeIdentifiers

/// DocumentGroup이 연 코스 창. 내비게이션 바와 브라우저로 돌아가는 버튼은 DocumentGroup이 제공하고,
/// 바를 숨기는 iPhone 가로 지도 화면의 뒤로가기 버튼만 dismiss로 문서를 닫는다.
struct CourseDocumentWindowView: View {
    let course: LoadedCourse

    /// 창에 끌어다 놓아 바꿔 연 코스. nil이면 DocumentGroup이 연 코스를 보여준다.
    @State private var droppedCourse: LoadedCourse?
    @State private var fileError: FilePreviewError?
    @State private var isDropTargeted = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CourseViewerView(course: droppedCourse ?? course) {
            dismiss()
        }
        // Files 앱 등에서 GPX·TCX 파일을 끌어다 놓으면 이 창에서 연다.
        .dropDestination(for: DroppedCourseFile.self) { files, _ in
            guard let file = files.first else { return false }
            switch file.result {
            case .success(let course):
                droppedCourse = course
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
