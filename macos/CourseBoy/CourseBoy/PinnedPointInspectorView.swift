import SwiftUI
import CourseBoyKit

/// 구간 선택과 pin 선택이 동시에 있을 수 있으므로, 각각 있으면 세로로 쌓아서 표시한다.
struct SelectionInspectorStack: View {
    var trackPoints: [TrackPoint]
    var rangeSelection: ChartRangeSelection?
    var pinnedDistanceKm: Double?
    var onClearPin: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if let range = rangeSelection {
                    RangeStatsInspectorView(trackPoints: trackPoints, range: range).content
                }
                if rangeSelection != nil, pinnedDistanceKm != nil {
                    Divider().padding(.horizontal, 12)
                }
                if let km = pinnedDistanceKm {
                    PinnedPointInspectorView(
                        trackPoints: trackPoints,
                        distanceKm: km,
                        onClear: onClearPin
                    ).content
                }
            }
        }
    }
}

/// 사용자가 고도그래프 또는 지도 경로를 클릭해 지정한 임시 pin 위치의 상세 정보 인스펙터.
struct PinnedPointInspectorView: View {
    var trackPoints: [TrackPoint]
    var distanceKm: Double
    var onClear: (() -> Void)? = nil

    private var info: RouteHoverInfo? {
        routeHoverInfo(trackPoints: trackPoints, nearestToDistanceKm: distanceKm)
    }

    private var progressStats: RouteElevationProgressStats? {
        let progress = RouteElevationProgress(trackPoints: trackPoints)
        guard let idx = info?.trackIndex else { return nil }
        return progress.stats(at: idx)
    }

    private var totalKm: Double { trackPoints.last?.cumKm ?? 0 }

    var body: some View {
        ScrollView { content }
    }

    /// SelectionInspectorStack에서 재사용하기 위해 스크롤 뷰 없이 노출.
    @ViewBuilder
    var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if let info {
                section(title: "위치", icon: "location") {
                    infoRow("시작점으로부터", value: formatKm(info.distanceKm))
                    infoRow("종료점까지", value: formatKm(max(0, totalKm - info.distanceKm)))
                    infoRow("고도", value: formatEle(info.elevationMeters))
                    infoRow("경사", value: formatGrade(info.gradePercent),
                            valueColor: gradeColor(info.gradePercent))
                    infoRow("방향", value: formatRouteDirection(info))
                }

                if let progressStats {
                    section(title: "누적 고도", icon: "mountain.2") {
                        infoRow("시작점부터 누적 상승",
                                value: formatDeltaEle(progressStats.ascentFromStart, sign: "+"),
                                valueColor: .red)
                        infoRow("시작점부터 누적 하강",
                                value: formatDeltaEle(progressStats.descentFromStart, sign: "-"),
                                valueColor: .blue)
                        infoRow("종료점까지 남은 상승",
                                value: formatDeltaEle(progressStats.ascentToEnd, sign: "+"),
                                valueColor: .red)
                        infoRow("종료점까지 남은 하강",
                                value: formatDeltaEle(progressStats.descentToEnd, sign: "-"),
                                valueColor: .blue)
                    }
                }

                section(title: "좌표", icon: "mappin.and.ellipse") {
                    infoRow("위도", value: String(format: "%.6f", info.lat))
                    infoRow("경도", value: String(format: "%.6f", info.lon))
                }
            } else {
                Text("선택한 위치의 데이터를 찾을 수 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label("선택 위치", systemImage: "mappin.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let onClear {
                    Button {
                        onClear()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("선택 해제")
                }
            }
            Text(formatKm(distanceKm))
                .font(.title3.weight(.semibold))
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

    private func formatDeltaEle(_ value: Double, sign: String) -> String {
        guard value > 0.5 else { return "—" }
        return String(format: "%@%.0f m", sign, value)
    }

    private func formatGrade(_ percent: Double?) -> String {
        guard let percent else { return "—" }
        return String(format: "%+.1f%%", percent)
    }

    private func gradeColor(_ percent: Double?) -> Color {
        guard let percent else { return .primary }
        if percent > 0.5 { return .red }
        if percent < -0.5 { return .blue }
        return .primary
    }
}
