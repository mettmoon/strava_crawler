import SwiftUI

struct CueSheetListView: View {
    let course: LoadedCourse
    @Binding var selectedCueID: UUID?

    private var progress: RouteElevationProgress {
        RouteElevationProgress(trackPoints: course.trackPoints)
    }

    var body: some View {
        if course.cuePoints.isEmpty {
            ContentUnavailableView {
                Label("큐시트 없음", systemImage: "list.bullet")
            } description: {
                Text("이 파일에는 표시할 웨이포인트나 CoursePoint가 없습니다.")
            }
            .frame(maxWidth: .infinity, minHeight: 140)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        } else {
            LazyVStack(spacing: 8) {
                ForEach(course.sortedCuePoints) { cue in
                    CueSheetRow(
                        cue: cue,
                        isSelected: cue.id == selectedCueID,
                        progress: cueProgress(cue)
                    )
                    .id(cue.id)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedCueID = cue.id == selectedCueID ? nil : cue.id
                        }
                    }
                }
            }
        }
    }

    private func cueProgress(_ cue: CourseCuePoint) -> RouteElevationProgressStats? {
        let index = Geo.nearestIndex(course.trackPoints, lat: cue.lat, lon: cue.lon)
        return progress.stats(at: index)
    }
}

private struct CueSheetRow: View {
    let cue: CourseCuePoint
    let isSelected: Bool
    let progress: RouteElevationProgressStats?

    private var glyph: CuePointGlyph {
        cuePointGlyph(for: cue.pointType)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CueGlyphView(glyph: glyph)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(cue.displayName)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(formatRouteDistance(cue.distanceKm))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text(cuePointLabel(for: cue.pointType))
                    if let progress {
                        Text("상승 \(formatRouteElevation(progress.ascentFromStart))")
                        Text("잔여 \(formatRouteElevation(progress.ascentToEnd))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                if !cue.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(cue.notes)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(isSelected ? 4 : 2)
                }
            }
        }
        .padding(12)
        .background(
            isSelected ? glyph.color.opacity(0.16) : Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isSelected ? glyph.color.opacity(0.65) : Color.clear, lineWidth: 1)
        }
    }
}

private struct CueGlyphView: View {
    let glyph: CuePointGlyph

    var body: some View {
        ZStack {
            Circle()
                .fill(glyph.color.opacity(0.16))
            if let symbol = glyph.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(glyph.color)
            } else if let text = glyph.text {
                Text(text)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(glyph.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: 34, height: 34)
    }
}
