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
                if course.totalDistanceKm > 0 {
                    Label(String(format: "%.1f km", course.totalDistanceKm), systemImage: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if course.totalElevationGainM > 0 {
                    Label(String(format: "%.0f m", course.totalElevationGainM), systemImage: "arrow.up.right")
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
