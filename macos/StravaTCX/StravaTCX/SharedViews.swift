import SwiftUI
import StravaTCXKit

// MARK: - 공통 UI 헬퍼

struct InfoRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .frame(maxWidth: 360)
    }
}

func categoryLabel(_ cat: String?) -> String {
    guard let cat else { return "—" }
    return cat == "HC" ? "HC" : "Cat \(cat)"
}

func pointTypeColor(_ pointType: String) -> Color {
    switch pointType {
    case "Summit": return .green
    case "Valley": return .blue
    case "Straight": return .secondary
    case "Sprint": return .purple
    default: return .orange   // First~Hors Category
    }
}

/// Table 행용 식별 래퍼 (CoursePointEntry 는 Identifiable 아님)
struct IdentifiedEntry: Identifiable {
    let id: Int
    let entry: CoursePointEntry
}

/// CoursePoint 엔트리의 RWGPS Notes 미리보기 텍스트.
func previewNotes(for e: CoursePointEntry) -> String {
    if e.isStart {
        let body = [Classification.normalizeDistanceText(e.dist), Classification.formatGrade(e.grade)]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        return e.gradeClass.arrow + body
    } else {
        return "🏁" + Classification.resolveSegmentName(e.segName)
    }
}
