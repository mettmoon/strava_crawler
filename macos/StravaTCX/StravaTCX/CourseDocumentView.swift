import AppKit
import SwiftUI
import StravaTCXKit

struct CourseDocumentView: View {
    @ObservedObject var document: CourseDocument
    var container: AppContainer
    var fileURL: URL?

    @State private var isEditing = false
    @State private var showing3D = false

    var body: some View {
        Group {
            if isEditing {
                CourseEditorView(
                    course: document.course,
                    onSave: { isEditing = false },
                    onCancel: { isEditing = false }
                )
                .navigationTitle(document.course.title)
                .navigationSubtitle("코스 편집")
            } else {
                CourseWorkspaceView(
                    course: document.course,
                    container: container,
                    onEdit: { isEditing = true },
                    onShow3D: { showing3D = true }
                )
                .onAppear {
                    closeWelcomeWindows()
                }
            }
        }
        .sheet(isPresented: $showing3D) {
            Course3DPreview(course: document.course)
        }
    }

    private func closeWelcomeWindows() {
        closeWelcomeWindowsNow()
        DispatchQueue.main.async {
            closeWelcomeWindowsNow()
        }
    }

    private func closeWelcomeWindowsNow() {
        NSApp.windows
            .filter { $0.identifier?.rawValue == "StravaTCXWelcomeWindow" }
            .forEach { $0.close() }
    }
}

private struct Course3DPreview: View {
    @ObservedObject var course: CourseRecord

    var body: some View {
        let pts = course.allTrackPoints
        Group {
            if pts.isEmpty {
                ContentUnavailableView {
                    Label("경로 데이터 없음", systemImage: "mountain.2")
                } description: {
                    Text("이 코스에는 아직 경로 데이터가 없습니다.")
                }
            } else {
                Route3DView(trackPoints: pts)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
    }
}
