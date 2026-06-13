import SwiftUI
import SwiftData
import StravaTCXKit

// MARK: - CourseCuesheetSidebar

/// 코스 워크스페이스 좌측 사이드바.
/// 큐시트 항목을 거리 순서로 나열하고 선택을 바인딩한다.
struct CourseCuesheetSidebar: View {
    @Bindable var course: CourseRecord
    @Binding var selectedCueIDs: Set<UUID>

    private var sortedCues: [CourseCuePoint] {
        course.cuePoints.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    var body: some View {
        let pts = course.allTrackPoints
        let elevationProgress = RouteElevationProgress(trackPoints: pts)

        VStack(spacing: 0) {
            HStack {
                Text("큐시트")
                    .font(.subheadline.bold())
                Spacer()
                Text("\(course.cuePoints.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if course.cuePoints.isEmpty {
                ContentUnavailableView {
                    Label("큐시트 없음", systemImage: "list.bullet")
                } description: {
                    Text("이 코스에는 큐시트 항목이 없습니다.")
                        .font(.caption)
                }
            } else {
                List(selection: $selectedCueIDs) {
                    ForEach(sortedCues) { cue in
                        let progress = cueElevationProgress(for: cue, trackPoints: pts, progress: elevationProgress)
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cue.name.isEmpty ? cuePointLabel(for: cue.pointType) : cue.name)
                                    .font(.body)
                                    .lineLimit(1)
                                HStack {
                                    Text(cuePointLabel(for: cue.pointType))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            VStack {
                                if let progress {
                                    HStack(spacing: 2) {
                                        Image(systemName: "arrow.up.right")
                                        Text("\(formatAccumulatedElevation(progress.ascentFromStart))")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                }
                                if cue.distanceMeters > 0 {
                                    Text(String(format: "%.1f km", cue.distanceMeters / 1000))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(cue.id)
                    }
                }
            }
        }
    }

    private func cueElevationProgress(
        for cue: CourseCuePoint,
        trackPoints pts: [TrackPoint],
        progress: RouteElevationProgress
    ) -> RouteElevationProgressStats? {
        progress.stats(at: Geo.nearestIndex(pts, lat: cue.lat, lon: cue.lon))
    }

    private func formatAccumulatedElevation(_ meters: Double) -> String {
        String(format: "%.0f m", meters)
    }
}

// MARK: - CourseCueInspectorView

/// 코스 워크스페이스 우측 인스펙터.
/// 선택된 큐 항목의 상세 정보를 표시한다.
/// - 시작점으로부터의 거리, 종료지점까지 거리, 고도
/// - 이전 큐와의 거리/고도 차이
/// - 다음 큐와의 거리/고도 차이
struct CourseCueInspectorView: View {
    var course: CourseRecord
    var selectedCueID: UUID?

    private var sortedCues: [CourseCuePoint] {
        course.cuePoints.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    private var trackPoints: [TrackPoint] { course.allTrackPoints }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(course.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let cueID = selectedCueID,
               let cue = course.cuePoints.first(where: { $0.id == cueID }) {
                ScrollView {
                    cueDetail(cue: cue)
                        .padding(16)
                }
            } else {
                ContentUnavailableView {
                    Label("큐를 선택하세요", systemImage: "mappin.and.ellipse")
                } description: {
                    Text("좌측 목록에서 큐 항목을 선택하면 상세 정보가 표시됩니다.")
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func cueDetail(cue: CourseCuePoint) -> some View {
        let pts = trackPoints
        let totalKm = pts.last?.cumKm ?? 0
        let cueIdx = Geo.nearestIndex(pts, lat: cue.lat, lon: cue.lon)
        let cueKm = cueIdx.map { pts[$0].cumKm } ?? (cue.distanceMeters / 1000)
        let cueEle = cueIdx.flatMap { pts[$0].ele }
        let elevationProgress = RouteElevationProgress(trackPoints: pts).stats(at: cueIdx)

        let cues = sortedCues
        let pos = cues.firstIndex(where: { $0.id == cue.id })
        let prev = (pos.flatMap { $0 > 0 ? cues[$0 - 1] : nil })
        let next = (pos.flatMap { $0 + 1 < cues.count ? cues[$0 + 1] : nil })

        VStack(alignment: .leading, spacing: 20) {
            // 헤더 (이름 + 타입)
            VStack(alignment: .leading, spacing: 4) {
                Text(cue.name.isEmpty ? cuePointLabel(for: cue.pointType) : cue.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text(cuePointLabel(for: cue.pointType))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // 요약: 시작/종료/고도
            section(title: "위치", icon: "location") {
                infoRow("시작점으로부터", value: formatKm(cueKm))
                infoRow("종료점까지", value: formatKm(max(0, totalKm - cueKm)))
                infoRow("고도", value: formatEle(cueEle))
            }

            section(title: "누적 고도", icon: "mountain.2") {
                infoRow("시작점부터 누적 상승", value: formatEle(elevationProgress?.ascentFromStart), valueColor: .red)
                infoRow("시작점부터 누적 하강", value: formatEle(elevationProgress?.descentFromStart), valueColor: .blue)
                infoRow("종료점까지 남은 상승", value: formatEle(elevationProgress?.ascentToEnd), valueColor: .red)
                infoRow("종료점까지 남은 하강", value: formatEle(elevationProgress?.descentToEnd), valueColor: .blue)
            }

            // 이전 큐
            section(title: "이전 큐", icon: "arrow.up.to.line") {
                if let prev {
                    let prevName = prev.name.isEmpty ? cuePointLabel(for: prev.pointType) : prev.name
                    infoRow("이름", value: prevName, valueColor: .primary)
                    infoRow("거리 차이", value: formatKm(max(0, (cue.distanceMeters - prev.distanceMeters) / 1000)))
                    infoRow("고도 차이", value: formatEleDelta(from: prev, to: cue, pts: pts))
                } else {
                    Text("이전 큐가 없습니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
            }

            // 다음 큐
            section(title: "다음 큐", icon: "arrow.down.to.line") {
                if let next {
                    let nextName = next.name.isEmpty ? cuePointLabel(for: next.pointType) : next.name
                    infoRow("이름", value: nextName, valueColor: .primary)
                    infoRow("거리 차이", value: formatKm(max(0, (next.distanceMeters - cue.distanceMeters) / 1000)))
                    infoRow("고도 차이", value: formatEleDelta(from: cue, to: next, pts: pts))
                } else {
                    Text("다음 큐가 없습니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
            }

            if !cue.notes.isEmpty {
                section(title: "메모", icon: "note.text") {
                    Text(cue.notes)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, icon: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(nil)
            VStack(spacing: 0) { content() }
                .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func infoRow(_ label: String, value: String, valueColor: Color = .primary) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) { Divider().padding(.leading, 12) }
    }

    private func formatKm(_ km: Double) -> String {
        if km < 1 { return String(format: "%.0f m", km * 1000) }
        return String(format: "%.2f km", km)
    }

    private func formatEle(_ ele: Double?) -> String {
        guard let ele else { return "—" }
        return String(format: "%.0f m", ele)
    }

    private func formatEleDelta(from a: CourseCuePoint, to b: CourseCuePoint, pts: [TrackPoint]) -> String {
        guard let aIdx = Geo.nearestIndex(pts, lat: a.lat, lon: a.lon),
              let bIdx = Geo.nearestIndex(pts, lat: b.lat, lon: b.lon),
              let aEle = pts[aIdx].ele, let bEle = pts[bIdx].ele else { return "—" }
        let diff = bEle - aEle
        let sign = diff > 0 ? "+" : (diff < 0 ? "" : "")
        return String(format: "%@%.0f m", sign, diff)
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
