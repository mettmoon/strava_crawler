import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CourseBoyKit

struct CourseDocumentView: View {
    @ObservedObject var document: CourseDocument
    var container: AppContainer
    var fileURL: URL?

    @State private var isEditing = false
    @State private var showing3D = false
    @State private var showingShare = false
    @State private var registeredRecentFileURL: URL?

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
                    onShare: { showingShare = true },
                    onShow3D: { showing3D = true }
                )
            }
        }
        .onAppear {
            closeWelcomeWindows()
            registerRecentCourseIfNeeded()
            detachFromImportedSourceFileIfNeeded()
        }
        .onChange(of: fileURL) { _, _ in
            registerRecentCourseIfNeeded()
        }
        .sheet(isPresented: $showing3D) {
            Course3DPreview(course: document.course)
        }
        .sheet(isPresented: $showingShare) {
            CourseShareView(course: document.course)
        }
        .focusedSceneValue(
            \.courseCommandHandler,
            CourseCommandHandler(
                edit: { isEditing = true },
                share: { if !isEditing { showingShare = true } },
                copySegmentInfo: { copySegmentInfoToPasteboard() },
                canShare: !isEditing && !document.course.allTrackPoints.isEmpty,
                canCopySegmentInfo: !document.course.segmentSnapshots.isEmpty
            )
        )
    }

    private func copySegmentInfoToPasteboard() {
        let text = document.course.segmentClipboardText
        guard !text.isEmpty else { NSSound.beep(); return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !pasteboard.setString(text, forType: .string) {
            NSSound.beep()
        }
    }

    private func registerRecentCourseIfNeeded() {
        guard let fileURL,
              let normalizedURL = CourseDocument.normalizedReadableFileURL(fileURL),
              normalizedURL != registeredRecentFileURL
        else { return }

        NSDocumentController.shared.noteNewRecentDocumentURL(normalizedURL)
        registeredRecentFileURL = normalizedURL
    }

    /// TCX·GPX 는 읽기만 하고 원본을 고쳐 쓰지 않는다. 그런 파일로 열린 문서는 원본과의 연결을 끊어
    /// 저장하지 않은 새 csb 문서로 바꾼다. 그래야 저장할 때 원본을 덮어쓰지 않고 csb 저장 창이 뜬다.
    private func detachFromImportedSourceFileIfNeeded() {
        guard let fileURL,
              let sourceURL = CourseDocument.normalizedReadableFileURL(fileURL),
              CourseImportFileCoder.readableFilenameExtensions.contains(sourceURL.pathExtension.lowercased())
        else { return }

        // 문서 열기 절차가 끝난 뒤에 바꾼다.
        DispatchQueue.main.async {
            guard let nsDocument = NSDocumentController.shared.documents.first(where: {
                $0.fileURL?.standardizedFileURL == sourceURL
            }) else { return }

            nsDocument.fileURL = nil
            nsDocument.fileType = UTType.coursePlan.identifier
            nsDocument.fileModificationDate = nil
            nsDocument.displayName = sourceURL.deletingPathExtension().lastPathComponent

            // 원본과 끊긴 문서는 파일도 자동저장본도 없어서, 그대로 앱이 종료되면 다시 열 때 창만 복원되고
            // 내용은 빈 코스가 된다. 자동저장본을 미리 만들어 두어 코스가 그대로 복원되게 한다.
            // 변경이 없는 문서는 자동저장이 아무 일도 하지 않으므로 변경된 것으로 표시한 뒤 저장하고,
            // 편집 없이 창을 닫을 때 저장 여부를 묻지 않도록 저장이 끝나면 표시를 되돌린다.
            nsDocument.updateChangeCount(.changeDone)
            nsDocument.autosave(withImplicitCancellability: false) { _ in
                nsDocument.updateChangeCount(.changeCleared)
            }
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
            .filter { $0.identifier?.rawValue == "CourseBoyWelcomeWindow" }
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
