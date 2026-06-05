import SwiftUI
import StravaTCXKit

// MARK: - CourseRow (사이드바 행)

struct CourseRow: View {
    let course: CourseRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(course.title)
                .font(.body)
                .lineLimit(1)
            HStack(spacing: 8) {
                Label("\(course.routePoints.count) 경유지", systemImage: "mappin")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !course.cuePoints.isEmpty {
                    Label("\(course.cuePoints.count) 큐", systemImage: "flag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if course.totalDistanceKm > 0 {
                    Text(String(format: "%.1f km", course.totalDistanceKm))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(course.createdAt, style: .date)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
