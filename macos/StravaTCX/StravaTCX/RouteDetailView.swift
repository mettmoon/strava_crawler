import SwiftUI
import StravaTCXKit

struct RouteDetailView: View {
    @Environment(ImportCoordinator.self) private var coordinator
    @Bindable var record: RouteRecord

    @State private var course: TCXCourse?
    @State private var entries: [CoursePointEntry] = []
    @State private var parseError: String?

    var body: some View {
        Group {
            switch record.status {
            case .processing: processingView
            case .failed:     failedView
            case .ready:      readyView
            }
        }
        .task(id: record.persistentModelID) { loadCourse() }
    }

    // MARK: - 상태별 화면

    private var processingView: some View {
        let p = coordinator.progress(for: record)
        return ContentUnavailableView {
            Label("처리 중", systemImage: "arrow.down.circle")
        } description: {
            Text(p?.message ?? "TCX 다운로드·세그먼트 수집 중…")
        }
    }

    private var failedView: some View {
        ContentUnavailableView {
            Label("처리 실패", systemImage: "exclamationmark.triangle")
        } description: {
            Text(record.errorMessage ?? "알 수 없는 오류")
        } actions: {
            Button("다시 시도") { coordinator.retry(record) }
                .buttonStyle(.borderedProminent)
        }
    }

    private var readyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let parseError {
                    Label(parseError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
                summarySection
                segmentsSection
                coursePointsSection
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - 구성요소

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(record.title)
                .font(.headline)
                .lineLimit(2)
            Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var summarySection: some View {
        Section {
            VStack(spacing: 0) {
                SummaryRow("Route ID", record.routeID)
                Divider().padding(.leading, 8)
                SummaryRow("Trackpoint", "\(record.trackPointCount) 개")
                Divider().padding(.leading, 8)
                SummaryRow("세그먼트", "\(record.segments.count) 개")
                Divider().padding(.leading, 8)
                SummaryRow("최소 카테고리", record.minCategory.map(categoryLabel) ?? "전체")
                Divider().padding(.leading, 8)
                SummaryRow("CoursePoint", "\(entries.count) 개")
            }
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
        } header: {
            sectionHeader("요약", systemImage: "doc.text")
        }
    }

    private var segmentsSection: some View {
        Section {
            Table(record.segments) {
                TableColumn("#") { s in
                    Text(s.order.map(String.init) ?? "—")
                        .foregroundStyle(.secondary)
                }
                .width(28)
                TableColumn("이름") { s in Text(s.name).lineLimit(1) }
                TableColumn("카테고리") { s in
                    Text(categoryLabel(s.climbCategory))
                        .foregroundStyle(s.climbCategory == nil ? Color.secondary : Color.orange)
                }
                .width(70)
                TableColumn("거리") { s in
                    Text(s.distanceText ?? "—").foregroundStyle(.secondary)
                }
                .width(70)
                TableColumn("경사") { s in
                    let g = Classification.gradeClass(s.avgGrade)
                    Text("\(g.arrow) \(s.avgGrade ?? "—")")
                }
                .width(80)
            }
            .tableStyle(.inset)
            .alternatingRowBackgrounds()
            .frame(minHeight: 140)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } header: {
            sectionHeader("세그먼트", systemImage: "mountain.2")
        }
    }

    private var coursePointsSection: some View {
        Section {
            Table(rows) {
                TableColumn("위치") { r in
                    Text(r.entry.isStart ? "시작" : "종료")
                        .foregroundStyle(r.entry.isStart ? .primary : .secondary)
                }
                .width(44)
                TableColumn("타입") { r in
                    Text(r.entry.pointType)
                        .foregroundStyle(pointTypeColor(r.entry.pointType))
                }
                .width(100)
                TableColumn("Notes") { r in
                    Text(previewNotes(for: r.entry))
                        .monospaced()
                        .lineLimit(1)
                }
            }
            .tableStyle(.inset)
            .alternatingRowBackgrounds()
            .frame(minHeight: 180)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } header: {
            HStack {
                sectionHeader("CoursePoint", systemImage: "flag.checkered")
                Spacer()
                Picker("최소 카테고리", selection: $record.minCategory) {
                    Text("전체").tag(String?.none)
                    Text("4↑").tag(String?.some("4"))
                    Text("3↑").tag(String?.some("3"))
                    Text("2↑").tag(String?.some("2"))
                    Text("1↑").tag(String?.some("1"))
                    Text("HC").tag(String?.some("HC"))
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.mini)
                .onChange(of: record.minCategory) { _, _ in recomputeEntries() }
            }
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    private var rows: [IdentifiedEntry] {
        entries
            .sorted { $0.idx < $1.idx }
            .enumerated()
            .map { IdentifiedEntry(id: $0.offset, entry: $0.element) }
    }

    // MARK: - 로직

    private func loadCourse() {
        course = nil; parseError = nil; entries = []
        guard record.status == .ready, !record.tcxData.isEmpty else { return }
        do {
            course = try TCXCourse(data: record.tcxData)
            recomputeEntries()
        } catch {
            parseError = error.localizedDescription
        }
    }

    private func recomputeEntries() {
        guard let course else { return }
        entries = Cuesheet.makeEntries(
            trackPoints: course.trackPoints,
            segments: record.segments,
            minCategory: record.minCategory
        ).entries
        record.coursePointCount = entries.count
    }
}

// MARK: - SummaryRow

private struct SummaryRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
