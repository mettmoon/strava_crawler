import SwiftUI

struct CueSheetListView: View {
    static let profileSelectionRowID = "profile-selection-row"
    static let startEndpointRowID = "cuesheet-endpoint-start"
    static let endEndpointRowID = "cuesheet-endpoint-end"

    static func rowID(for selection: CourseProfileSelection, in course: LoadedCourse) -> String {
        switch selection.endpointKind(in: course) {
        case .start: return startEndpointRowID
        case .end: return endEndpointRowID
        case .none: return profileSelectionRowID
        }
    }

    let course: LoadedCourse
    @Binding var selectedCueID: UUID?
    @Binding var selectedProfilePoint: CourseProfileSelection?

    private var progress: RouteElevationProgress {
        RouteElevationProgress(trackPoints: course.trackPoints)
    }

    var body: some View {
        if listItems.isEmpty {
            ContentUnavailableView {
                Label("큐시트 없음", systemImage: "list.bullet")
            } description: {
                Text("이 파일에는 표시할 웨이포인트나 CoursePoint가 없습니다.")
            }
            .frame(maxWidth: .infinity, minHeight: 140)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        } else {
            LazyVStack(spacing: 8) {
                ForEach(listItems) { item in
                    switch item {
                    case .endpoint(let endpoint):
                        TrackEndpointRow(
                            endpoint: endpoint,
                            remainingDistanceKm: remainingDistanceKm(from: endpoint.distanceKm),
                            isSelected: isEndpointSelected(endpoint)
                        )
                        .id(endpoint.rowID)
                        .onTapGesture {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                toggleEndpointSelection(endpoint)
                            }
                        }

                    case .profile(let selection):
                        ProfileSelectionCueSheetRow(
                            selection: selection,
                            progress: profileProgress(selection),
                            remainingDistanceKm: remainingDistanceKm(from: selection.distanceKm)
                        )
                        .id(Self.profileSelectionRowID)

                    case .cue(let cue):
                        CueSheetRow(
                            cue: cue,
                            isSelected: cue.id == selectedCueID,
                            progress: cueProgress(cue),
                            remainingDistanceKm: remainingDistanceKm(from: cue.distanceKm)
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
    }

    private var listItems: [CueSheetListItem] {
        var items = course.sortedCuePoints.map(CueSheetListItem.cue)
        let endpoints = trackEndpoints
        let endpointIndices = Set(endpoints.map(\.trackIndex))
        if let selectedProfilePoint,
           !endpointIndices.contains(selectedProfilePoint.trackIndex) {
            items.append(.profile(selectedProfilePoint))
        }
        for endpoint in endpoints {
            items.append(.endpoint(endpoint))
        }
        return items.sorted { lhs, rhs in
            if lhs.distanceKm == rhs.distanceKm {
                return lhs.sortOrder < rhs.sortOrder
            }
            return lhs.distanceKm < rhs.distanceKm
        }
    }

    private var trackEndpoints: [TrackEndpoint] {
        var result: [TrackEndpoint] = []
        if let start = course.trackPoints.first {
            result.append(TrackEndpoint(kind: .start, point: start, trackIndex: 0))
        }
        if course.trackPoints.count > 1,
           let end = course.trackPoints.last {
            result.append(TrackEndpoint(kind: .end, point: end, trackIndex: course.trackPoints.count - 1))
        }
        return result
    }

    private func isEndpointSelected(_ endpoint: TrackEndpoint) -> Bool {
        selectedProfilePoint?.trackIndex == endpoint.trackIndex
    }

    private func toggleEndpointSelection(_ endpoint: TrackEndpoint) {
        if isEndpointSelected(endpoint) {
            selectedProfilePoint = nil
        } else {
            selectedCueID = nil
            selectedProfilePoint = CourseProfileSelection(
                trackIndex: endpoint.trackIndex,
                point: endpoint.point
            )
        }
    }

    private func cueProgress(_ cue: CourseCuePoint) -> RouteElevationProgressStats? {
        let index = Geo.nearestIndex(course.trackPoints, lat: cue.lat, lon: cue.lon)
        return progress.stats(at: index)
    }

    private func profileProgress(_ selection: CourseProfileSelection) -> RouteElevationProgressStats? {
        progress.stats(atDistanceKm: selection.distanceKm, trackPoints: course.trackPoints)
    }

    private func remainingDistanceKm(from distanceKm: Double) -> Double {
        max(0, course.totalDistanceKm - distanceKm)
    }
}

private enum CueSheetListItem: Identifiable {
    case endpoint(TrackEndpoint)
    case profile(CourseProfileSelection)
    case cue(CourseCuePoint)

    var id: String {
        switch self {
        case .endpoint(let endpoint):
            return endpoint.rowID
        case .profile:
            return CueSheetListView.profileSelectionRowID
        case .cue(let cue):
            return cue.id.uuidString
        }
    }

    var distanceKm: Double {
        switch self {
        case .endpoint(let endpoint):
            return endpoint.distanceKm
        case .profile(let selection):
            return selection.distanceKm
        case .cue(let cue):
            return cue.distanceKm
        }
    }

    var sortOrder: Int {
        switch self {
        case .endpoint(let endpoint):
            // Start goes before other items at the same distance; end goes after.
            return endpoint.kind == .start ? -1 : 2
        case .profile:
            return 0
        case .cue:
            return 1
        }
    }
}

private struct TrackEndpoint {
    enum Kind {
        case start
        case end

        var title: String {
            switch self {
            case .start: return "시작점"
            case .end: return "종료점"
            }
        }

        var symbol: String {
            switch self {
            case .start: return "flag.fill"
            case .end: return "flag.checkered"
            }
        }

        var color: Color {
            switch self {
            case .start: return .green
            case .end: return .red
            }
        }

        var rowID: String {
            switch self {
            case .start: return CueSheetListView.startEndpointRowID
            case .end: return CueSheetListView.endEndpointRowID
            }
        }
    }

    let kind: Kind
    let point: TrackPoint
    let trackIndex: Int

    var distanceKm: Double { point.cumKm }
    var elevation: Double? { point.ele }
    var rowID: String { kind.rowID }
}

private struct CueSheetRow: View {
    let cue: CourseCuePoint
    let isSelected: Bool
    let progress: RouteElevationProgressStats?
    let remainingDistanceKm: Double

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
                        Text("남은 \(formatRouteDistance(remainingDistanceKm))")
                        Text("남은 상승 \(formatRouteElevation(progress.ascentToEnd))")
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

private struct ProfileSelectionCueSheetRow: View {
    let selection: CourseProfileSelection
    let progress: RouteElevationProgressStats?
    let remainingDistanceKm: Double

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.cyan.opacity(0.16))
                Image(systemName: "scope")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.cyan)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("그래프 선택 위치")
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(formatRouteDistance(selection.distanceKm))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text("고도 \(formatRouteElevation(selection.elevationMeters))")
                    if let progress {
                        Text("남은 \(formatRouteDistance(remainingDistanceKm))")
                        Text("남은 상승 \(formatRouteElevation(progress.ascentToEnd))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
        .padding(12)
        .background(Color.cyan.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.cyan.opacity(0.65), lineWidth: 1)
        }
    }
}

private struct TrackEndpointRow: View {
    let endpoint: TrackEndpoint
    let remainingDistanceKm: Double
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(endpoint.kind.color.opacity(0.16))
                Image(systemName: endpoint.kind.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(endpoint.kind.color)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(endpoint.kind.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(formatRouteDistance(endpoint.distanceKm))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text("고도 \(formatRouteElevation(endpoint.elevation))")
                    if endpoint.kind == .start {
                        Text("남은 \(formatRouteDistance(remainingDistanceKm))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            }
        }
        .padding(12)
        .background(
            isSelected
                ? endpoint.kind.color.opacity(0.22)
                : Color(.secondarySystemGroupedBackground),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    isSelected ? endpoint.kind.color.opacity(0.9) : Color.clear,
                    lineWidth: isSelected ? 1.5 : 0
                )
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
