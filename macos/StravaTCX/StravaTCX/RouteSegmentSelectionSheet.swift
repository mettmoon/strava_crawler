import SwiftUI
import StravaTCXKit

struct RouteSegmentSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let route: Route
    let onCreate: ([SegmentInfo]) -> Void

    @State private var selectedSegmentIDs: Set<String>
    @State private var selectedBatchKinds: Set<CourseSegmentBatchKind> = []

    init(route: Route, onCreate: @escaping ([SegmentInfo]) -> Void) {
        self.route = route
        self.onCreate = onCreate
        _selectedSegmentIDs = State(initialValue: Set(route.segments.map(\.segmentID)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(20)

            Divider()

            batchControls
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider()

            segmentList
                .frame(minHeight: 300)

            Divider()

            footer
                .padding(20)
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 520, idealHeight: 620)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("포함할 구간")
                .font(.title3.weight(.semibold))
            Text(route.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private var batchControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("일괄 처리")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 14) {
                    ForEach(CourseSegmentBatchKind.allCases) { kind in
                        Toggle(kind.title, isOn: batchBinding(for: kind))
                            .toggleStyle(.checkbox)
                    }
                }

                HStack(alignment: .center, spacing: 8) {
                    Spacer()

                    Button("전체 선택") {
                        selectAllSegments()
                    }

                    Button("전체 해제") {
                        deselectAllSegments()
                    }

                    Button("일괄 체크") {
                        applyBatch(selected: true)
                    }
                    .disabled(selectedBatchKinds.isEmpty)

                    Button("일괄 해제") {
                        applyBatch(selected: false)
                    }
                    .disabled(selectedBatchKinds.isEmpty)
                }
            }
        }
    }

    @ViewBuilder
    private var segmentList: some View {
        if route.segments.isEmpty {
            ContentUnavailableView {
                Label("구간 없음", systemImage: "mountain.2")
            } description: {
                Text("이 경로에서 가져온 구간이 없습니다.")
            }
        } else {
            List {
                ForEach(route.segments.indices, id: \.self) { index in
                    let segment = route.segments[index]
                    SegmentSelectionRow(
                        segment: segment,
                        isSelected: Binding(
                            get: { selectedSegmentIDs.contains(segment.segmentID) },
                            set: { setSegment(segment, selected: $0) }
                        )
                    )
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(selectedSegmentIDs.count) / \(route.segments.count)개 선택")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button("취소", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("만들기") {
                onCreate(selectedSegments)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private var selectedSegments: [SegmentInfo] {
        route.segments.filter { selectedSegmentIDs.contains($0.segmentID) }
    }

    private func batchBinding(for kind: CourseSegmentBatchKind) -> Binding<Bool> {
        Binding(
            get: { selectedBatchKinds.contains(kind) },
            set: { isSelected in
                if isSelected {
                    selectedBatchKinds.insert(kind)
                } else {
                    selectedBatchKinds.remove(kind)
                }
            }
        )
    }

    private func setSegment(_ segment: SegmentInfo, selected: Bool) {
        if selected {
            selectedSegmentIDs.insert(segment.segmentID)
        } else {
            selectedSegmentIDs.remove(segment.segmentID)
        }
    }

    private func selectAllSegments() {
        selectedSegmentIDs = Set(route.segments.map(\.segmentID))
    }

    private func deselectAllSegments() {
        selectedSegmentIDs.removeAll()
    }

    private func applyBatch(selected: Bool) {
        let ids = route.segments
            .filter { segment in
                selectedBatchKinds.contains { kind in kind.matches(segment) }
            }
            .map(\.segmentID)

        for id in ids {
            if selected {
                selectedSegmentIDs.insert(id)
            } else {
                selectedSegmentIDs.remove(id)
            }
        }
    }
}

private enum CourseSegmentBatchKind: String, CaseIterable, Identifiable, Hashable {
    case hc
    case category1
    case category2
    case category3
    case category4
    case up
    case flat
    case down

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hc: return "HC"
        case .category1: return "1"
        case .category2: return "2"
        case .category3: return "3"
        case .category4: return "4"
        case .up: return "오르막"
        case .flat: return "평지"
        case .down: return "내리막"
        }
    }

    func matches(_ segment: SegmentInfo) -> Bool {
        let category = Classification.normalizeClimbCategory(segment.climbCategory)
        switch self {
        case .hc:
            return category == "HC"
        case .category1:
            return category == "1"
        case .category2:
            return category == "2"
        case .category3:
            return category == "3"
        case .category4:
            return category == "4"
        case .up:
            return category == nil && Classification.gradeClass(segment.avgGrade) == .up
        case .flat:
            return category == nil && Classification.gradeClass(segment.avgGrade) == .flat
        case .down:
            return category == nil && Classification.gradeClass(segment.avgGrade) == .down
        }
    }
}

private struct SegmentSelectionRow: View {
    let segment: SegmentInfo
    @Binding var isSelected: Bool

    var body: some View {
        Toggle(isOn: $isSelected) {
            HStack(spacing: 12) {
                Text(segment.order.map(String.init) ?? "-")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)

                VStack(alignment: .leading, spacing: 4) {
                    Text(segment.name)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(segment.distanceText ?? "-")
                        Text(gradeText)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Text(kindText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(kindColor)
                    .frame(minWidth: 56, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .toggleStyle(.checkbox)
        .padding(.vertical, 5)
    }

    private var gradeText: String {
        let gradeClass = Classification.gradeClass(segment.avgGrade)
        return "\(gradeClass.arrow) \(segment.avgGrade ?? "-")"
    }

    private var kindText: String {
        if let category = Classification.normalizeClimbCategory(segment.climbCategory) {
            return categoryLabel(category)
        }

        switch Classification.gradeClass(segment.avgGrade) {
        case .up:
            return "오르막"
        case .flat:
            return "평지"
        case .down:
            return "내리막"
        }
    }

    private var kindColor: Color {
        if Classification.normalizeClimbCategory(segment.climbCategory) != nil {
            return .orange
        }

        switch Classification.gradeClass(segment.avgGrade) {
        case .up:
            return .red
        case .flat:
            return .secondary
        case .down:
            return .blue
        }
    }
}
