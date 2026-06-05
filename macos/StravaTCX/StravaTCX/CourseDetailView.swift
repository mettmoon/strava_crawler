import SwiftUI
import SwiftData
import StravaTCXKit

// MARK: - CourseDetailView

/// 코스 선택 시 오른쪽 인스펙터 패널.
/// 큐시트 목록을 표시한다.
struct CourseDetailView: View {
    @Bindable var course: CourseRecord

    var body: some View {
        VStack(spacing: 0) {
            // 상단 타이틀
            HStack {
                Text(course.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // 큐시트 목록 (읽기 전용)
            HStack {
                Text("큐시트")
                    .font(.subheadline.bold())
                Spacer()
                Text("\(course.cuePoints.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if course.cuePoints.isEmpty {
                Text("큐시트가 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else {
                List(course.cuePoints) { cue in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cue.name.isEmpty ? cue.pointType : cue.name)
                            .font(.body)
                        HStack {
                            Text(cuePointLabel(for: cue.pointType))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            if cue.distanceMeters > 0 {
                                Text(String(format: "%.1f km", cue.distanceMeters / 1000))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

// MARK: - CourseEditorWindowView

/// 별도 윈도우에서 코스를 편집한다. UUID로 SwiftData에서 코스를 조회한다.
struct CourseEditorWindowView: View {
    var courseID: UUID?
    @Query private var allCourses: [CourseRecord]

    private var course: CourseRecord? {
        guard let id = courseID else { return nil }
        return allCourses.first { $0.id == id }
    }

    var body: some View {
        if let course {
            CourseEditorView(course: course)
                .navigationTitle(course.title)
                .navigationSubtitle("코스 편집")
        } else {
            ContentUnavailableView("코스를 찾을 수 없음", systemImage: "map")
        }
    }
}
