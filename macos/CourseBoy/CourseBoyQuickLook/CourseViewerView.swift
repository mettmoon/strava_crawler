import SwiftUI

struct CourseViewerView: View {
    let course: LoadedCourse

    @State private var selectedCueID: UUID?
    @State private var selectedProfilePoint: CourseProfileSelection?
    @State private var selectedTab: CourseViewerTab = .summary
    @State private var elevationCueScrollRequest: ElevationCueScrollRequest?
    @State private var elevationHorizontalScrollPosition = 0.0

    private var selectedCue: CourseCuePoint? {
        guard let selectedCueID else { return nil }
        return course.cuePoints.first { $0.id == selectedCueID }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            CourseSummaryTab(
                course: course,
                selectedCue: selectedCue,
                selectedProfilePoint: selectedProfilePoint
            )
            .tabItem {
                Label("요약", systemImage: "chart.bar.doc.horizontal")
            }
            .tag(CourseViewerTab.summary)

            CourseMapTab(
                course: course,
                selectedCueID: linkedCueSelection,
                selectedProfilePoint: $selectedProfilePoint
            )
                .tabItem {
                    Label("지도", systemImage: "map")
                }
                .tag(CourseViewerTab.map)

            CourseElevationTab(
                course: course,
                selectedCueID: $selectedCueID,
                selectedProfilePoint: $selectedProfilePoint,
                cueScrollRequest: $elevationCueScrollRequest,
                horizontalScrollPosition: $elevationHorizontalScrollPosition,
                isActive: selectedTab == .elevation
            )
                .tabItem {
                    Label("고도그래프", systemImage: "mountain.2")
                }
                .tag(CourseViewerTab.elevation)

            CourseCueSheetTab(
                course: course,
                selectedCueID: linkedCueSelection,
                selectedProfilePoint: $selectedProfilePoint
            )
                .tabItem {
                    Label("큐시트", systemImage: "list.bullet.rectangle")
                }
                .tag(CourseViewerTab.cueSheet)
        }
    }

    private var linkedCueSelection: Binding<UUID?> {
        Binding {
            selectedCueID
        } set: { id in
            if let id, id != selectedCueID {
                elevationCueScrollRequest = ElevationCueScrollRequest(cueID: id)
            }
            if id != nil {
                selectedProfilePoint = nil
            }
            selectedCueID = id
        }
    }
}

private enum CourseViewerTab: Hashable {
    case summary
    case map
    case elevation
    case cueSheet
}

private struct ElevationCueScrollRequest: Equatable {
    var requestID = UUID()
    var cueID: UUID
}

private struct ElevationCueScrollAnchorRow: Identifiable {
    var id: UUID
    var spacerHeight: CGFloat
}

private struct CourseSummaryTab: View {
    let course: LoadedCourse
    let selectedCue: CourseCuePoint?
    let selectedProfilePoint: CourseProfileSelection?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CourseHeaderView(course: course)
                CourseSummaryGrid(course: course)
                if selectedCue != nil || selectedProfilePoint != nil {
                    ViewerSection(title: "선택한 큐", systemImage: "mappin.and.ellipse") {
                        SelectedCueDetailRows(
                            course: course,
                            selectedCue: selectedCue,
                            selectedProfilePoint: selectedProfilePoint
                        )
                    }
                }
                ViewerSection(title: "상세 정보", systemImage: "info.circle") {
                    CourseDetailRows(course: course)
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
    }
}

private struct CourseMapTab: View {
    let course: LoadedCourse
    @Binding var selectedCueID: UUID?
    @Binding var selectedProfilePoint: CourseProfileSelection?
    @State private var locateRequest: CourseLocateRequest?

    private var selectedCue: CourseCuePoint? {
        guard let selectedCueID else { return nil }
        return course.cuePoints.first { $0.id == selectedCueID }
    }

    var body: some View {
        ZStack {
            CourseMapView(
                course: course,
                selectedCueID: $selectedCueID,
                selectedProfilePoint: $selectedProfilePoint,
                locateRequest: $locateRequest
            )
            .ignoresSafeArea(.container, edges: [.top, .bottom])

            VStack {
                HStack {
                    Spacer()
                    locateButton
                }
                Spacer()
            }
            .padding(.top, 12)
            .padding(.trailing, 12)

            VStack {
                Spacer()
                if let selectedCue {
                    SelectedCueOverlay(cue: selectedCue) {
                        selectedCueID = nil
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                } else if let profilePoint = selectedProfilePoint {
                    SelectedProfilePointOverlay(course: course, selection: profilePoint) {
                        selectedProfilePoint = nil
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
        .toolbarBackground(.bar, for: .navigationBar, .tabBar)
        .toolbarBackground(.visible, for: .navigationBar, .tabBar)
    }

    private var locateButton: some View {
        Button {
            locateRequest = CourseLocateRequest()
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color(.separator), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("내 위치")
    }
}

private struct CourseElevationTab: View {
    let course: LoadedCourse
    @Binding var selectedCueID: UUID?
    @Binding var selectedProfilePoint: CourseProfileSelection?
    @Binding var cueScrollRequest: ElevationCueScrollRequest?
    @Binding var horizontalScrollPosition: Double
    let isActive: Bool

    var body: some View {
        GeometryReader { proxy in
            let viewportSize = proxy.size
            let profileSize = ElevationProfileView.preferredSize(
                trackPoints: course.trackPoints,
                availableWidth: viewportSize.width,
                availableHeight: graphViewportHeight(in: viewportSize)
            )
            let viewportWidth = max(1, viewportSize.width)
            let maxHorizontalOffset = max(0, profileSize.width - viewportWidth)
            let horizontalOffset = maxHorizontalOffset * CGFloat(horizontalScrollPosition)
            let renderWidth = max(profileSize.width, viewportWidth)
            let profileSelectionForDisplay = selectedProfilePoint ?? selectedCueProfilePoint

            VStack(spacing: 0) {
                ElevationProfileHeaderView(
                    trackPoints: course.trackPoints,
                    width: renderWidth,
                    contentWidth: profileSize.width,
                    visibleWidth: viewportWidth,
                    horizontalOffset: horizontalOffset
                )

                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical) {
                        ZStack(alignment: .topLeading) {
                            ElevationProfileView(
                                trackPoints: course.trackPoints,
                                cuePoints: course.sortedCuePoints,
                                selectedCueID: selectedCueID,
                                selectedProfilePoint: profileSelectionForDisplay,
                                contentWidth: profileSize.width,
                                visibleWidth: viewportWidth,
                                horizontalOffset: horizontalOffset,
                                onSelectProfilePoint: { selection in
                                    selectedProfilePoint = selection
                                    selectedCueID = nil
                                },
                                onSelectCue: { cueID in
                                    if selectedCueID == cueID {
                                        selectedCueID = nil
                                        selectedProfilePoint = nil
                                    } else {
                                        selectedProfilePoint = nil
                                        selectedCueID = cueID
                                    }
                                }
                            )
                            .frame(width: renderWidth, height: profileSize.height)
                            .offset(x: -horizontalOffset)

                            cueScrollAnchors(profileSize: profileSize)
                                .allowsHitTesting(false)
                        }
                        .frame(width: viewportWidth, height: profileSize.height, alignment: .topLeading)
                        .clipped()
                        .padding(.vertical, 12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .onChange(of: cueScrollRequest) { _, request in
                        consumeCueScrollRequest(request, using: scrollProxy)
                    }
                    .onChange(of: isActive) { _, active in
                        guard active else { return }
                        consumeCueScrollRequest(cueScrollRequest, using: scrollProxy, animated: false)
                    }
                    .onAppear {
                        consumeCueScrollRequest(cueScrollRequest, using: scrollProxy, animated: false)
                    }
                }

                if maxHorizontalOffset > 1 {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.left")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Slider(value: $horizontalScrollPosition, in: 0...1)
                            .accessibilityLabel("가로 위치")
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
            }
        }
        .background(Color(.systemGroupedBackground))
    }

    private func graphViewportHeight(in viewportSize: CGSize) -> CGFloat {
        max(
            1,
            viewportSize.height
                - ElevationProfileView.headerHeight
                - Self.graphVerticalPadding
        )
    }

    private var selectedCueProfilePoint: CourseProfileSelection? {
        guard let selectedCueID,
              let cue = course.cuePoints.first(where: { $0.id == selectedCueID }),
              let index = Geo.nearestIndex(course.trackPoints, lat: cue.lat, lon: cue.lon) else {
            return nil
        }
        return CourseProfileSelection(trackIndex: index, point: course.trackPoints[index])
    }

    @ViewBuilder
    private func cueScrollAnchors(profileSize: CGSize) -> some View {
        VStack(spacing: 0) {
            ForEach(cueScrollAnchorRows(profileHeight: profileSize.height)) { row in
                Color.clear
                    .frame(width: 1, height: row.spacerHeight)
                Color.clear
                    .frame(width: 1, height: 1)
                    .id(elevationCueAnchorID(row.id))
            }
        }
        .frame(width: 1, height: profileSize.height, alignment: .topLeading)
    }

    private func cueScrollAnchorRows(profileHeight: CGFloat) -> [ElevationCueScrollAnchorRow] {
        var cursor: CGFloat = 0
        return course.sortedCuePoints.map { cue in
            let targetY = min(
                max(
                    ElevationProfileView.yPosition(
                        distanceKm: cue.distanceKm,
                        trackPoints: course.trackPoints,
                        profileHeight: profileHeight
                    ),
                    0
                ),
                max(0, profileHeight - 1)
            )
            let spacerHeight = max(0, targetY - cursor)
            cursor += spacerHeight + 1
            return ElevationCueScrollAnchorRow(id: cue.id, spacerHeight: spacerHeight)
        }
    }

    private func consumeCueScrollRequest(
        _ request: ElevationCueScrollRequest?,
        using proxy: ScrollViewProxy,
        animated: Bool = true
    ) {
        guard isActive, let request else { return }
        let action = {
            proxy.scrollTo(elevationCueAnchorID(request.cueID), anchor: .center)
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.25), action)
        } else {
            action()
        }
        cueScrollRequest = nil
    }

    private func elevationCueAnchorID(_ id: UUID) -> String {
        "elevation-cue-\(id.uuidString)"
    }

    private static let graphVerticalPadding: CGFloat = 24
}

private struct CourseCueSheetTab: View {
    let course: LoadedCourse
    @Binding var selectedCueID: UUID?
    @Binding var selectedProfilePoint: CourseProfileSelection?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CueSheetListView(
                        course: course,
                        selectedCueID: cueSelectionBinding,
                        selectedProfilePoint: $selectedProfilePoint
                    )
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: selectedCueID) { _, id in
                guard let id else { return }
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: selectedProfilePoint) { _, selection in
                guard let selection else { return }
                let rowID = CueSheetListView.rowID(for: selection, in: course)
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(rowID, anchor: .center)
                }
            }
        }
    }

    private var cueSelectionBinding: Binding<UUID?> {
        Binding {
            selectedCueID
        } set: { id in
            if id != nil {
                selectedProfilePoint = nil
            }
            selectedCueID = id
        }
    }
}

private struct SelectedCueOverlay: View {
    let cue: CourseCuePoint
    var onClose: () -> Void

    private var glyph: CuePointGlyph {
        cuePointGlyph(for: cue.pointType)
    }

    var body: some View {
        HStack(spacing: 12) {
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

            VStack(alignment: .leading, spacing: 3) {
                Text(cue.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(formatRouteDistance(cue.distanceKm)) · \(cuePointLabel(for: cue.pointType))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("선택 해제")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        }
    }
}

private struct SelectedProfilePointOverlay: View {
    let course: LoadedCourse
    let selection: CourseProfileSelection
    var onClose: () -> Void

    private var progress: RouteElevationProgressStats? {
        RouteElevationProgress(trackPoints: course.trackPoints)
            .stats(atDistanceKm: selection.distanceKm, trackPoints: course.trackPoints)
    }

    private var remainingDistanceKm: Double {
        max(0, course.totalDistanceKm - selection.distanceKm)
    }

    private var endpointKind: CourseTrackEndpointKind? {
        selection.endpointKind(in: course)
    }

    private var titleText: String {
        endpointKind?.title ?? "그래프 선택 위치"
    }

    private var accentColor: Color {
        switch endpointKind {
        case .start: return .green
        case .end: return .red
        case .none: return .cyan
        }
    }

    private var symbolName: String {
        switch endpointKind {
        case .start: return "flag.fill"
        case .end: return "flag.checkered"
        case .none: return "scope"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(accentColor.opacity(0.16))
                Image(systemName: symbolName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(accentColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(titleText)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(formatRouteDistance(selection.distanceKm)) · \(formatRouteElevation(selection.elevationMeters))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("남은 \(formatRouteDistance(remainingDistanceKm)) · 남은 상승 \(formatRouteElevation(progress?.ascentToEnd))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("선택 해제")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(.separator), lineWidth: 0.5)
        }
    }
}

private struct CourseHeaderView: View {
    let course: LoadedCourse

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(course.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(2)
                Text("\(course.fileKind.rawValue) · \(course.sourceURL.lastPathComponent)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

private struct CourseSummaryGrid: View {
    let course: LoadedCourse

    private var stats: CourseElevationStats {
        course.elevationStats
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: 8)]
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            MetricTile(
                title: "총 거리",
                value: formatRouteDistance(course.totalDistanceKm),
                systemImage: "road.lanes"
            )
            MetricTile(
                title: "획득고도",
                value: formatRouteElevation(stats.ascent),
                systemImage: "arrow.up.right"
            )
            MetricTile(
                title: "큐시트",
                value: formatRouteCount(course.cuePoints.count),
                systemImage: "list.bullet"
            )
            MetricTile(
                title: "트랙 포인트",
                value: "\(course.trackPoints.count)",
                systemImage: "point.3.connected.trianglepath.dotted"
            )
        }
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ViewerSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct CourseDetailRows: View {
    let course: LoadedCourse

    var body: some View {
        VStack(spacing: 0) {
            DetailRow(title: "파일", value: course.sourceURL.lastPathComponent)
            DetailRow(title: "형식", value: course.fileKind.rawValue)
            DetailRow(title: "트랙 포인트", value: "\(course.trackPoints.count)")
            DetailRow(title: "경유지", value: "\(course.routePoints.count)")
            DetailRow(title: "큐시트", value: "\(course.cuePoints.count)")
            DetailRow(title: "최저 고도", value: formatRouteElevation(course.elevationStats.min))
            DetailRow(title: "최고 고도", value: formatRouteElevation(course.elevationStats.max))
            DetailRow(title: "누적 하강", value: formatRouteElevation(course.elevationStats.descent))
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SelectedCueDetailRows: View {
    let course: LoadedCourse
    let selectedCue: CourseCuePoint?
    let selectedProfilePoint: CourseProfileSelection?

    var body: some View {
        VStack(spacing: 0) {
            if let selectedCue {
                DetailRow(title: "선택한 큐", value: selectedCue.displayName)
                DetailRow(title: "종류", value: cuePointLabel(for: selectedCue.pointType))
                DetailRow(title: "위치", value: formatRouteDistance(selectedCue.distanceKm))
                DetailRow(title: "고도", value: formatRouteElevation(selectedCueElevation))
                if !selectedCue.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    DetailRow(title: "메모", value: selectedCue.notes)
                }
            }
            if let selectedProfilePoint {
                let endpoint = selectedProfilePoint.endpointKind(in: course)
                DetailRow(
                    title: endpoint.map { "\($0.title) 거리" } ?? "그래프 선택 거리",
                    value: formatRouteDistance(selectedProfilePoint.distanceKm)
                )
                DetailRow(
                    title: endpoint.map { "\($0.title) 고도" } ?? "그래프 선택 고도",
                    value: formatRouteElevation(selectedProfilePoint.elevationMeters)
                )
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var selectedCueElevation: Double? {
        guard let selectedCue,
              let index = Geo.nearestIndex(course.trackPoints, lat: selectedCue.lat, lon: selectedCue.lon) else {
            return nil
        }
        return course.trackPoints[index].ele
    }
}

private struct DetailRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 12)
        }
    }
}
