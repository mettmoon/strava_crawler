import SwiftUI
import CourseBoyKit

struct SegmentRow: View {
    let segment: SegmentInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(segment.name)
                .fontWeight(.medium)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let cat = segment.climbCategory {
                    Text(categoryLabel(cat))
                        .foregroundStyle(.orange)
                }
                if let dist = segment.distanceText {
                    Text(dist)
                }
                let g = Classification.gradeClass(segment.avgGrade)
                Text("\(g.arrow) \(segment.avgGrade ?? "—")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
