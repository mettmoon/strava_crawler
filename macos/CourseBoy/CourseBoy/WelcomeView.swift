import AppKit
import SwiftUI

/// 메인 윈도우 — 환영 디스패치 화면.
/// 좌측 사이드바 없이, 사용자가 어디로 갈지 선택하는 진입점.
struct WelcomeView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument

    @State private var recentCourses: [RecentCourseFile] = []
    @State private var openError: String?

    var body: some View {
        HStack(spacing: 0) {
            welcomeActions
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !recentCourses.isEmpty {
                Divider()
                RecentCoursesPanel(
                    files: recentCourses,
                    onOpen: openRecentCourse
                )
                .frame(width: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("CourseBoy")
        .onAppear(perform: reloadRecentCourses)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            reloadRecentCourses()
        }
        .background(WelcomeWindowIdentifierSetter())
        .alert("코스 파일을 열 수 없습니다", isPresented: Binding(
            get: { openError != nil },
            set: { if !$0 { openError = nil } }
        )) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(openError ?? "")
        }
    }

    private var welcomeActions: some View {
        VStack(spacing: 32) {
            VStack(spacing: 8) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 84, height: 84)
                Text("CourseBoy")
                    .font(.largeTitle.bold())
                Text("Strava 경로를 가져오고, 큐시트를 편집하고, 내보냅니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 12) {
                DispatchButton(
                    title: "경로에서 코스 만들기",
                    subtitle: "Strava 경로를 골라 코스로 변환",
                    systemImage: "bicycle"
                ) { openWindow(id: "route-library") }

                DispatchButton(
                    title: "구간 불러오기",
                    subtitle: "저장된 구간 열기",
                    systemImage: "mountain.2"
                ) { openWindow(id: "segment-library") }

                DispatchButton(
                    title: "새 코스 문서",
                    subtitle: "CSB 문서로 코스 작성",
                    systemImage: "doc.badge.plus"
                ) { newDocument { CourseDocument() } }

                DispatchButton(
                    title: "TCX/GPX 파일 불러오기",
                    subtitle: "파일에서 코스 문서 만들기",
                    systemImage: "square.and.arrow.down"
                ) { importCourseFile() }

                DispatchButton(
                    title: "코스 문서 열기",
                    subtitle: "CSB 파일 열기",
                    systemImage: "folder"
                ) { openCourseDocument() }
            }
            .frame(maxWidth: 380)

            Spacer()
        }
        .padding(.top, 60)
        .padding(.horizontal, 40)
    }

    private func reloadRecentCourses() {
        recentCourses = NSDocumentController.shared.recentDocumentURLs
            .filter { CourseDocument.readableFilenameExtensions.contains($0.pathExtension.lowercased()) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .map(RecentCourseFile.init(url:))
    }

    private func openCourseDocument() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = CourseDocument.readableContentTypes
        panel.prompt = "열기"
        panel.message = "CSB 코스 문서를 선택하세요"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            do {
                try await openDocument(at: url)
            } catch {
                await MainActor.run {
                    openError = error.localizedDescription
                    reloadRecentCourses()
                }
            }
        }
    }

    private func importCourseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = CourseImportFileCoder.readableContentTypes
        panel.prompt = "불러오기"
        panel.message = "TCX 또는 GPX 코스 파일을 선택하세요"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let course = try CourseImportFileCoder.makeRecord(from: url)
            let document = CourseDocument(course: course)
            newDocument { document }
        } catch {
            openError = error.localizedDescription
        }
    }

    private func openRecentCourse(_ file: RecentCourseFile) {
        Task {
            do {
                try await openDocument(at: file.url)
            } catch {
                await MainActor.run {
                    openError = error.localizedDescription
                    reloadRecentCourses()
                }
            }
        }
    }
}

private struct WelcomeWindowIdentifierSetter: NSViewRepresentable {
    func makeNSView(context: Context) -> WelcomeWindowIdentifierView {
        WelcomeWindowIdentifierView()
    }

    func updateNSView(_ nsView: WelcomeWindowIdentifierView, context: Context) {
        nsView.markWindow()
    }
}

private final class WelcomeWindowIdentifierView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        markWindow()
    }

    func markWindow() {
        DispatchQueue.main.async { [weak self] in
            self?.window?.identifier = NSUserInterfaceItemIdentifier("CourseBoyWelcomeWindow")
        }
    }
}

private struct RecentCourseFile: Identifiable, Hashable {
    let url: URL

    var id: URL { url }
    var title: String { url.deletingPathExtension().lastPathComponent }
    var parentPath: String { url.deletingLastPathComponent().path }
}

private struct RecentCoursesPanel: View {
    let files: [RecentCourseFile]
    let onOpen: (RecentCourseFile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent")
                .font(.headline)
                .padding(.horizontal, 18)
                .padding(.top, 24)
                .padding(.bottom, 10)

            List(files) { file in
                Button {
                    onOpen(file)
                } label: {
                    RecentCourseRow(file: file)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10))
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(.background.secondary)
    }
}

private struct RecentCourseRow: View {
    let file: RecentCourseFile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.title)
                    .font(.body)
                    .lineLimit(1)
                Text(file.parentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private struct DispatchButton: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 36)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.body.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
