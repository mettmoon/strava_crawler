import SwiftUI
import UniformTypeIdentifiers

/// 다른 코스 파일(csb·tcx·gpx)에서 섹션만 꺼내 편집 중인 코스에 넣을 때 쓴다.
enum CourseSectionImporter {
    static var readableContentTypes: [UTType] { CourseDocument.readableContentTypes }

    /// 파일의 섹션을 파일 순서대로 돌려준다. 경로가 없는 빈 섹션은 뺀다.
    /// 같은 파일을 여러 번 넣거나 편집 중인 코스 자신의 파일을 넣어도 겹치지 않게 id를 모두 새로 만든다.
    static func sections(from url: URL) throws -> [CourseSection] {
        let record: CourseRecord
        switch url.pathExtension.lowercased() {
        case "csb":
            record = try CoursePlanFileCoder.makeRecord(from: Data(contentsOf: url))
        default:
            record = try CourseImportFileCoder.makeRecord(from: url)
        }
        return record.sections
            .filter { !$0.trackPoints.isEmpty }
            .map(withFreshIDs)
    }

    static func withFreshIDs(_ section: CourseSection) -> CourseSection {
        var copy = section
        copy.id = UUID()
        for index in copy.routePoints.indices { copy.routePoints[index].id = UUID() }
        for index in copy.legs.indices { copy.legs[index].id = UUID() }
        for index in copy.cuePoints.indices { copy.cuePoints[index].id = UUID() }
        return copy
    }
}

/// 파일에서 읽은 섹션 묶음. 섹션이 여러 개일 때 고르는 시트에 넘긴다.
struct CourseSectionImportCandidates: Identifiable {
    let id = UUID()
    let fileName: String
    let sections: [CourseSection]
}

/// 파일에 섹션이 여러 개일 때 넣을 섹션을 고르는 시트. 처음에는 모두 골라 둔다.
struct CourseSectionImportPicker: View {
    let candidates: CourseSectionImportCandidates
    var onAdd: ([CourseSection]) -> Void
    var onCancel: () -> Void

    @State private var selectedIDs: Set<UUID>

    init(
        candidates: CourseSectionImportCandidates,
        onAdd: @escaping ([CourseSection]) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.candidates = candidates
        self.onAdd = onAdd
        self.onCancel = onCancel
        _selectedIDs = State(initialValue: Set(candidates.sections.map(\.id)))
    }

    private var selectedSections: [CourseSection] {
        candidates.sections.filter { selectedIDs.contains($0.id) }
    }

    private var allSelected: Bool { selectedIDs.count == candidates.sections.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("추가할 섹션 선택")
                    .font(.headline)
                Text(candidates.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(candidates.sections.enumerated()), id: \.element.id) { index, section in
                        Toggle(isOn: binding(for: section.id)) {
                            HStack(spacing: 8) {
                                Text("섹션 \(index + 1)")
                                Spacer()
                                Text("큐시트 \(section.cuePoints.count)개")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(formatRouteDistance(section.distanceKm))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 70, alignment: .trailing)
                            }
                        }
                        .toggleStyle(.checkbox)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        if index + 1 < candidates.sections.count { Divider() }
                    }
                }
            }
            .frame(maxHeight: 260)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            HStack {
                Button(allSelected ? "모두 해제" : "모두 선택") {
                    selectedIDs = allSelected ? [] : Set(candidates.sections.map(\.id))
                }
                Spacer()
                Button("취소", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("\(selectedIDs.count)개 추가") { onAdd(selectedSections) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedIDs.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedIDs.contains(id) },
            set: { isOn in
                if isOn { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
            }
        )
    }
}
