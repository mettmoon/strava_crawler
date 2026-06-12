import SwiftUI
import SwiftData
import StravaTCXKit

/// 모든 코스를 보여주는 별도 윈도우.
/// "+ 새 코스"로 새 코스를 만들고 즉시 편집기를 연다. "불러오기"로 보기, "편집"으로 편집기 윈도우.
struct CourseLibraryView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.modelContext) private var context
    @Query(sort: \CourseRecord.createdAt, order: .reverse) private var courses: [CourseRecord]

    @State private var searchText = ""

    private var filteredCourses: [CourseRecord] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return courses }
        return courses.filter { $0.title.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("이름으로 검색", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    createCourse()
                } label: {
                    Label("새 코스", systemImage: "plus")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()
            content
        }
        .frame(minWidth: 360, idealWidth: 440, minHeight: 420, idealHeight: 600)
        .navigationTitle("코스 목록")
        .focusedSceneValue(\.createCourseAction, { createCourse() })
    }

    @ViewBuilder
    private var content: some View {
        if courses.isEmpty {
            ContentUnavailableView {
                Label("코스 없음", systemImage: "map")
            } description: {
                Text("+ 버튼으로 새 코스를 만들거나\n경로 워크스페이스에서 \"코스로 만들기\"를 사용하세요.")
            }
        } else if filteredCourses.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                ForEach(filteredCourses) { course in
                    CourseLibraryRow(
                        course: course,
                        onLoad: { openWindow(id: "course-workspace", value: course.id) },
                        onEdit: { openWindow(id: "course-editor", value: course.id) }
                    )
                }
                .onDelete(perform: deleteCourses)
            }
        }
    }

    private func createCourse() {
        let newCourse = CourseRecord(title: "새 코스 \(courses.count + 1)")
        context.insert(newCourse)
        openWindow(id: "course-editor", value: newCourse.id)
    }

    private func deleteCourses(_ offsets: IndexSet) {
        let targets = offsets.map { filteredCourses[$0] }
        for course in targets { context.delete(course) }
    }
}

private struct CourseLibraryRow: View {
    let course: CourseRecord
    let onLoad: () -> Void
    let onEdit: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CourseRow(course: course)
            Spacer()
            Button("불러오기", action: onLoad)
                .buttonStyle(.bordered)
                .controlSize(.small)
            Button("편집", action: onEdit)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}
