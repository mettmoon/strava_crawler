import CoursePreviewCore
import SwiftUI

struct CoursePreviewView: View {
    let course: LoadedCourse

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            GeometryReader { proxy in
                if proxy.size.width >= 760 {
                    HStack(spacing: 0) {
                        CoursePreviewMapView(course: course)
                            .frame(minWidth: 420)
                        Divider()
                        details
                            .frame(width: min(340, proxy.size.width * 0.36))
                    }
                } else {
                    VStack(spacing: 0) {
                        CoursePreviewMapView(course: course)
                            .frame(minHeight: 280)
                        Divider()
                        details
                            .frame(height: min(300, proxy.size.height * 0.45))
                    }
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(course.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(course.fileKind.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }

            HStack(spacing: 24) {
                PreviewMetric(
                    title: "거리",
                    value: formatRouteDistance(course.totalDistanceKm),
                    systemImage: "point.topleft.down.to.point.bottomright.curvepath"
                )
                PreviewMetric(
                    title: "획득 고도",
                    value: formatRouteElevation(course.elevationStats.ascent),
                    systemImage: "arrow.up.right"
                )
                PreviewMetric(
                    title: "하강 고도",
                    value: formatRouteElevation(course.elevationStats.descent),
                    systemImage: "arrow.down.right"
                )
                PreviewMetric(
                    title: "큐",
                    value: formatRouteCount(course.cuePoints.count),
                    systemImage: "list.bullet.rectangle"
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Label("고도 프로필", systemImage: "mountain.2")
                    .font(.headline)
                CoursePreviewElevationChart(trackPoints: course.trackPoints)
                    .frame(height: 150)
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Label("큐시트", systemImage: "list.bullet.rectangle")
                    .font(.headline)
                if course.sortedCuePoints.isEmpty {
                    Text("등록된 큐포인트가 없습니다.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(course.sortedCuePoints) { cue in
                                CoursePreviewCueRow(cue: cue)
                                Divider()
                            }
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxHeight: .infinity)
        }
    }
}

private struct PreviewMetric: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.monospacedDigit().weight(.medium))
            }
        }
    }
}

private struct CoursePreviewCueRow: View {
    let cue: CourseCuePoint

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: cueSymbol(for: cue.pointType))
                .foregroundStyle(cueColor(for: cue.pointType))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(cue.displayName)
                    .lineLimit(1)
                if !cue.notes.isEmpty {
                    Text(cue.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(formatRouteDistance(cue.distanceKm))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
    }
}

private func cueSymbol(for type: String) -> String {
    switch type {
    case "Summit": return "mountain.2.fill"
    case "Valley": return "arrow.down.to.line"
    case "Water": return "drop.fill"
    case "Food": return "fork.knife"
    case "Danger": return "exclamationmark.triangle.fill"
    case "Left": return "arrow.turn.up.left"
    case "Right": return "arrow.turn.up.right"
    case "Straight": return "arrow.up"
    case "First Aid": return "cross.fill"
    case "Sprint": return "bolt.fill"
    default: return "mappin"
    }
}

private func cueColor(for type: String) -> Color {
    switch type {
    case "Water": return .blue
    case "Food": return .orange
    case "Danger", "First Aid": return .red
    case "Summit": return .green
    case "Left", "Right": return .purple
    default: return .secondary
    }
}
