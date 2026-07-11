import SwiftUI
import CourseBoyKit

/// 고도 그래프 또는 큐시트에서 선택한 구간의 통계 정보를 표시한다.
struct RangeStatsInspectorView: View {
    var trackPoints: [TrackPoint]
    var range: ChartRangeSelection
    var onClear: (() -> Void)? = nil

    private var stats: RouteRangeStats? {
        routeRangeStats(trackPoints: trackPoints, range: range)
    }

    var body: some View {
        ScrollView { content }
    }

    /// SelectionInspectorStack에서 재사용하기 위해 스크롤 뷰 없이 노출.
    @ViewBuilder
    var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            if let stats {
                section(title: "구간", icon: "ruler") {
                    infoRow("시작", value: formatKm(stats.startKm))
                    infoRow("종료", value: formatKm(stats.endKm))
                    infoRow("길이", value: formatKm(stats.lengthKm),
                            valueColor: .accentColor)
                }

                section(title: "고도", icon: "mountain.2") {
                    infoRow("시작 고도", value: formatEle(stats.startEle))
                    infoRow("종료 고도", value: formatEle(stats.endEle))
                    infoRow("최고", value: formatEle(stats.maxEle))
                    infoRow("최저", value: formatEle(stats.minEle))
                    infoRow("총 상승", value: formatDeltaEle(stats.ascentMeters, sign: "+"),
                            valueColor: .red)
                    infoRow("총 하강", value: formatDeltaEle(stats.descentMeters, sign: "-"),
                            valueColor: .blue)
                    infoRow("순 고도차",
                            value: formatNetEle(stats),
                            valueColor: netEleColor(stats))
                }

                section(title: "경사", icon: "angle") {
                    infoRow("평균 경사", value: formatGrade(stats.averageGradePercent),
                            valueColor: gradeColor(stats.averageGradePercent))
                }
            } else {
                Text("선택 구간이 너무 짧습니다.")
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
                Label("선택 구간", systemImage: "selection.pin.in.out")
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
            Text(range.isDragging ? "선택 중…" : "선택 완료")
                .font(.title3.weight(.semibold))
                .foregroundStyle(range.isDragging ? .secondary : .primary)
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

    private func formatNetEle(_ stats: RouteRangeStats) -> String {
        guard let s = stats.startEle, let e = stats.endEle else { return "—" }
        let diff = e - s
        let sign = diff > 0 ? "+" : (diff < 0 ? "" : "")
        return String(format: "%@%.0f m", sign, diff)
    }

    private func netEleColor(_ stats: RouteRangeStats) -> Color {
        guard let s = stats.startEle, let e = stats.endEle else { return .primary }
        if e - s > 0.5 { return .red }
        if e - s < -0.5 { return .blue }
        return .primary
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
