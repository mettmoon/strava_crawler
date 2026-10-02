import CoursePreviewCore
import SwiftUI

struct CueSheetListView: View {
    static let profileSelectionRowID = "profile-selection-row"
    static let currentLocationRowID = "current-location-row"
    static let startEndpointRowID = "cuesheet-endpoint-start"
    static let endEndpointRowID = "cuesheet-endpoint-end"

    static func rowID(for selection: CourseProfileSelection, in course: LoadedCourse) -> String {
        switch selection.endpointKind(in: course) {
        case .start: return startEndpointRowID
        case .end: return endEndpointRowID
        case .none: return profileSelectionRowID
        }
    }

    /// 구간 행 id. 시작 큐 행과 id가 같으면 보기를 바꿀 때 SwiftUI가 같은 행으로 보고 갱신하지 않으므로 따로 둔다.
    static func sectionRowID(_ section: CourseClimbSection) -> String {
        "climb-section-\(section.id.uuidString)"
    }

    /// 구간 보기에서는 구간의 시작·정상 큐 행이 구간 행으로 바뀐다.
    static func rowID(forCueID id: UUID, sections: [CourseClimbSection]?, groupsClimbSections: Bool) -> AnyHashable {
        guard groupsClimbSections,
              let section = sections?.first(where: { $0.startCue.id == id || $0.summitCue?.id == id }) else {
            return id
        }
        return sectionRowID(section)
    }

    let course: LoadedCourse
    @Binding var selectedCueID: UUID?
    @Binding var selectedProfilePoint: CourseProfileSelection?
    /// 코스 위로 인식된 현재 위치. 선택 지점과 별개의 항목으로 표시한다.
    var currentLocation: CourseProfileSelection? = nil
    /// 오르막 구간. nil이면 아직 계산 중이라 구간 보기에서도 큐를 그대로 보여준다.
    var climbSections: [CourseClimbSection]? = nil
    /// true면 구간의 시작·정상 큐를 숨기고 그 자리에 구간 행을 둔다.
    var groupsClimbSections = false
    /// true면 오르막 구간(또는 구간을 이루는 큐)과 현재 위치만 남긴다.
    var climbsOnly = false

    /// 트랙 포인트 전체를 훑어 만들기 때문에 코스마다 한 번만 계산해 둔다. 행마다 새로 만들지 않는다.
    @State private var cachedProgress: (courseID: UUID, progress: RouteElevationProgress)?

    private var progress: RouteElevationProgress {
        if let cachedProgress, cachedProgress.courseID == course.id {
            return cachedProgress.progress
        }
        return RouteElevationProgress(trackPoints: course.trackPoints)
    }

    var body: some View {
        content
            .onChange(of: course.id, initial: true) { _, id in
                cachedProgress = (id, RouteElevationProgress(trackPoints: course.trackPoints))
            }
    }

    @ViewBuilder
    private var content: some View {
        let listItems = listItems
        if climbsOnly && climbSections == nil {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 140)
        } else if climbsOnly && !listItems.contains(where: \.isClimb) {
            ContentUnavailableView {
                Label("구간 없음", systemImage: "mountain.2")
            } description: {
                Text("큐시트에 등급·스프린트 오르막 항목이 없습니다.")
            }
            .frame(maxWidth: .infinity, minHeight: 140)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        } else if listItems.isEmpty {
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

                    case .currentLocation(let location):
                        CurrentLocationCueSheetRow(
                            location: location,
                            progress: profileProgress(location),
                            remainingDistanceKm: remainingDistanceKm(from: location.distanceKm)
                        )
                        .id(Self.currentLocationRowID)

                    case .section(let section):
                        NavigationLink(value: ClimbSectionRoute(section: section)) {
                            ClimbSectionRow(
                                section: section,
                                isSelected: selectedCueID == section.startCue.id
                                    || (selectedCueID != nil && selectedCueID == section.summitCue?.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .id(Self.sectionRowID(section))

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
        let sections = climbSections ?? []
        // 오르막만 보기에서는 다운힐 구간을 뺀다.
        let shownSections = climbsOnly ? sections.filter { !$0.isDownhill } : sections
        let sectionCueIDs = Set(shownSections.flatMap { [$0.startCue.id, $0.summitCue?.id].compactMap { $0 } })
        var items: [CueSheetListItem] = []

        if groupsClimbSections {
            items += shownSections.map(CueSheetListItem.section)
            if !climbsOnly {
                items += course.sortedCuePoints
                    .filter { !sectionCueIDs.contains($0.id) }
                    .map(CueSheetListItem.cue)
            }
        } else {
            items += course.sortedCuePoints
                .filter { !climbsOnly || sectionCueIDs.contains($0.id) }
                .map(CueSheetListItem.cue)
        }

        if !climbsOnly {
            let endpoints = trackEndpoints
            let endpointIndices = Set(endpoints.map(\.trackIndex))
            if let selectedProfilePoint,
               !endpointIndices.contains(selectedProfilePoint.trackIndex) {
                items.append(.profile(selectedProfilePoint))
            }
            for endpoint in endpoints {
                items.append(.endpoint(endpoint))
            }
        }
        if let currentLocation {
            items.append(.currentLocation(currentLocation))
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
    case currentLocation(CourseProfileSelection)
    case section(CourseClimbSection)
    case cue(CourseCuePoint)

    /// 오르막만 보기에서 남는 항목인지. 큐 전체 보기에서는 목록에 남은 큐가 모두 구간을 이루는 큐다.
    var isClimb: Bool {
        switch self {
        case .section, .cue: return true
        case .endpoint, .profile, .currentLocation: return false
        }
    }

    var id: String {
        switch self {
        case .endpoint(let endpoint):
            return endpoint.rowID
        case .profile:
            return CueSheetListView.profileSelectionRowID
        case .currentLocation:
            return CueSheetListView.currentLocationRowID
        case .section(let section):
            return CueSheetListView.sectionRowID(section)
        case .cue(let cue):
            return cue.id.uuidString
        }
    }

    var distanceKm: Double {
        switch self {
        case .endpoint(let endpoint):
            return endpoint.distanceKm
        case .profile(let selection), .currentLocation(let selection):
            return selection.distanceKm
        case .section(let section):
            return section.startKm
        case .cue(let cue):
            return cue.distanceKm
        }
    }

    var sortOrder: Double {
        switch self {
        case .endpoint(let endpoint):
            // Start goes before other items at the same distance; end goes after.
            return endpoint.kind == .start ? -1 : 2
        case .currentLocation:
            return -0.5
        case .profile:
            return 0
        case .section, .cue:
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

private struct CurrentLocationCueSheetRow: View {
    let location: CourseProfileSelection
    let progress: RouteElevationProgressStats?
    let remainingDistanceKm: Double

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue)
                Image(systemName: "location.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("현재 위치")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(formatRouteDistance(location.distanceKm))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text("고도 \(formatRouteElevation(location.elevationMeters))")
                    Text("남은 \(formatRouteDistance(remainingDistanceKm))")
                    if let progress {
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
        .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.blue.opacity(0.7), lineWidth: 1.5)
        }
        .accessibilityElement(children: .combine)
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

struct CueGlyphView: View {
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
