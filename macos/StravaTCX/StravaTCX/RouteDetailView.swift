import SwiftUI
import AppKit
import StravaTCXKit

/// 저장된 라우트 상세 — 요약 + 세그먼트 + CoursePoint(필터) + TCX 내보내기.
///
/// CoursePoint 와 내보낼 TCX 는 저장돼 있지 않고, 원본 TCX·세그먼트로부터 현재
/// `minCategory` 기준으로 즉석 계산한다.
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
            case .failed: failedView
            case .ready: readyView
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
        }
    }

    private var readyView: some View {
        TabView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let parseError {
                        Label(parseError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    summary
                    segmentsSection
                    coursePointsSection
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .tabItem { Label("상세", systemImage: "doc.text") }

            RouteMapView(trackPoints: course?.trackPoints ?? [])
                .tabItem { Label("지도", systemImage: "map.fill") }

            Route3DView(trackPoints: course?.trackPoints ?? [])
                .tabItem { Label("3D 경로", systemImage: "mountain.2.fill") }
        }
    }

    // MARK: - ready 구성요소

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.largeTitle.bold())
                Text(record.createdAt.formatted(date: .long, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { export() } label: {
                Label("TCX 내보내기…", systemImage: "square.and.arrow.up")
            }
            .controlSize(.large)
            .disabled(course == nil)
        }
    }

    private var summary: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                InfoRow("Route ID", record.routeID)
                InfoRow("Trackpoint", "\(record.trackPointCount) 개")
                InfoRow("세그먼트", "\(record.segments.count) 개")
                InfoRow("최소 카테고리", record.minCategory.map(categoryLabel) ?? "전체")
                InfoRow("CoursePoint", "\(entries.count) 개")
            }
            .padding(8)
        } label: {
            Label("요약", systemImage: "doc.text")
        }
    }

    private var segmentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("세그먼트").font(.headline)
            Table(record.segments) {
                TableColumn("#") { s in Text(s.order.map(String.init) ?? "—") }
                    .width(28)
                TableColumn("이름") { s in Text(s.name) }
                TableColumn("카테고리") { s in
                    Text(categoryLabel(s.climbCategory))
                        .foregroundStyle(s.climbCategory == nil ? Color.secondary : Color.orange)
                }
                .width(80)
                TableColumn("거리") { s in Text(s.distanceText ?? "—") }.width(80)
                TableColumn("경사") { s in
                    let g = Classification.gradeClass(s.avgGrade)
                    Text("\(g.arrow) \(s.avgGrade ?? "—")")
                }
                .width(90)
            }
            .frame(minHeight: 180)
        }
    }

    private var coursePointsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("CoursePoint (\(entries.count))").font(.headline)
                Spacer()
                Picker("최소 카테고리", selection: $record.minCategory) {
                    Text("전체").tag(String?.none)
                    Text("4↑").tag(String?.some("4"))
                    Text("3↑").tag(String?.some("3"))
                    Text("2↑").tag(String?.some("2"))
                    Text("1↑").tag(String?.some("1"))
                    Text("HC").tag(String?.some("HC"))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                .onChange(of: record.minCategory) { _, _ in recomputeEntries() }
            }
            Table(rows) {
                TableColumn("위치") { r in
                    Text(r.entry.isStart ? "시작" : "종료")
                        .foregroundStyle(r.entry.isStart ? .primary : .secondary)
                }
                .width(48)
                TableColumn("PointType") { r in
                    Text(r.entry.pointType).foregroundStyle(pointTypeColor(r.entry.pointType))
                }
                .width(130)
                TableColumn("Notes (RWGPS)") { r in Text(previewNotes(for: r.entry)).monospaced() }
            }
            .frame(minHeight: 220)
        }
    }

    private var rows: [IdentifiedEntry] {
        entries
            .sorted { $0.idx < $1.idx }
            .enumerated()
            .map { IdentifiedEntry(id: $0.offset, entry: $0.element) }
    }

    // MARK: - 로직

    private func loadCourse() {
        course = nil
        parseError = nil
        entries = []
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
            trackPoints: course.trackPoints, segments: record.segments, minCategory: record.minCategory
        ).entries
        record.coursePointCount = entries.count
    }

    private func export() {
        guard let course,
              let cued = try? course.build(entries: entries, forRWGPS: false),
              let rwgps = try? course.build(entries: entries, forRWGPS: true) else {
            NSSound.beep()
            return
        }
        Exporter.saveToFolder(prefix: record.fileNamePrefix, cued: cued.data, rwgps: rwgps.data)
    }
}
