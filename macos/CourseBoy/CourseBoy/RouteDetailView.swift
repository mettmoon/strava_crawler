import SwiftUI
import CourseBoyKit

struct RouteDetailView: View {
    @Environment(RouteListViewModel.self) private var routeVM
    var route: Route
    var onCourseParsed: ((TCXCourse?) -> Void)?
    var onHighlight: (([TrackPoint]) -> Void)?

    @State private var course: TCXCourse?
    @State private var entries: [CoursePointEntry] = []
    @State private var parseError: String?
    @State private var selectedSegmentID: String?
    @State private var minCategory: String?

    var body: some View {
        Group {
            switch route.status {
            case .processing: processingView
            case .failed:     failedView
            case .ready:      readyView
            }
        }
        .task(id: route.id) {
            minCategory = route.minCategory
            loadCourse()
        }
    }

    // MARK: - 상태별 화면

    private var processingView: some View {
        let p = routeVM.progress(for: route.id)
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
            Text(route.errorMessage ?? "알 수 없는 오류")
        } actions: {
            Button("다시 시도") { routeVM.retry(routeID: route.id) }
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
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - 구성요소

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(route.title)
                .font(.headline)
                .lineLimit(2)
            Text(route.createdAt.formatted(date: .abbreviated, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var summarySection: some View {
        Section {
            VStack(spacing: 0) {
                SummaryRow("Route ID", route.id)
                Divider().padding(.leading, 8)
                SummaryRow("Trackpoint", "\(route.trackPointCount) 개")
                Divider().padding(.leading, 8)
                SummaryRow("세그먼트", "\(route.segments.count) 개")
                Divider().padding(.leading, 8)
                SummaryRow("최소 카테고리", minCategory.map(categoryLabel) ?? "전체")
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
            Table(route.segments, selection: $selectedSegmentID) {
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
            .onChange(of: selectedSegmentID) { _, id in
                guard let id, let seg = route.segments.first(where: { $0.segmentID == id }),
                      let pts = course?.trackPoints else {
                    onHighlight?([]); return
                }
                onHighlight?(sliceTrackPoints(pts, for: seg))
            }
        } header: {
            sectionHeader("세그먼트", systemImage: "mountain.2")
        }
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    // MARK: - 하이라이트 헬퍼

    private func sliceTrackPoints(_ pts: [TrackPoint], for seg: SegmentInfo) -> [TrackPoint] {
        guard let sp = seg.startPoint, let ep = seg.endPoint else { return [] }
        let startIdx = Geo.nearestIndex(pts, lat: sp[0], lon: sp[1]) ?? 0
        let endIdx   = Geo.nearestIndex(pts, lat: ep[0], lon: ep[1], startIdx: startIdx + 1) ?? (pts.count - 1)
        guard startIdx < endIdx else { return [] }
        return Array(pts[startIdx...endIdx])
    }

    private func loadCourse() {
        course = nil; parseError = nil; entries = []
        onCourseParsed?(nil)
        guard route.status == .ready, !route.tcxData.isEmpty else { return }
        do {
            let parsed = try TCXCourse(data: route.tcxData)
            course = parsed
            onCourseParsed?(parsed)
            recomputeEntries()
        } catch {
            parseError = error.localizedDescription
        }
    }

    private func recomputeEntries() {
        guard let course else { return }
        entries = Cuesheet.makeEntries(
            trackPoints: course.trackPoints,
            segments: route.segments,
            minCategory: minCategory
        ).entries
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
