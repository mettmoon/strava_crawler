import CoursePreviewCore
import SwiftUI

struct CourseViewerView: View {
    let course: LoadedCourse

    @State private var selectedCueID: UUID?
    @State private var selectedProfilePoint: CourseProfileSelection?
    @State private var selectedTab: CourseViewerTab = .summary
    @State private var locationTracker = CourseLocationTracker()

    /// 코스 위로 인식된 현재 위치. 코스 밖이거나 트래킹 중이 아니면 nil.
    private var currentRouteLocation: CourseProfileSelection? {
        locationTracker.currentLocation?.routeMatch
    }

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
                selectedProfilePoint: $selectedProfilePoint,
                locationTracker: locationTracker
            )
                .tabItem {
                    Label("지도", systemImage: "map")
                }
                .tag(CourseViewerTab.map)

            ClimbSectionsTab(course: course)
                .tabItem {
                    Label("구간", systemImage: "mountain.2")
                }
                .tag(CourseViewerTab.sections)

            CourseCueSheetTab(
                course: course,
                selectedCueID: linkedCueSelection,
                selectedProfilePoint: $selectedProfilePoint,
                currentLocation: currentRouteLocation
            )
                .tabItem {
                    Label("큐시트", systemImage: "list.bullet.rectangle")
                }
                .tag(CourseViewerTab.cueSheet)
        }
        .climbSectionDestination(course: course) { section in
            linkedCueSelection.wrappedValue = section.startCue.id
            selectedTab = .map
        }
        .onDisappear {
            locationTracker.stop()
        }
    }

    private var linkedCueSelection: Binding<UUID?> {
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

private enum CourseViewerTab: Hashable {
    case summary
    case map
    case sections
    case cueSheet
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
    @Bindable var locationTracker: CourseLocationTracker
    @AppStorage("mapShowsElevationChart") private var showsElevationChart = true
    @State private var isScrubbingElevationChart = false
    @Environment(\.openURL) private var openURL

    private var selectedCue: CourseCuePoint? {
        guard let selectedCueID else { return nil }
        return course.cuePoints.first { $0.id == selectedCueID }
    }

    var body: some View {
        VStack(spacing: 0) {
            mapLayer

            if showsElevationChart {
                MapElevationChartView(
                    course: course,
                    selectedCueID: $selectedCueID,
                    selectedProfilePoint: $selectedProfilePoint,
                    currentLocation: locationTracker.currentLocation?.routeMatch,
                    onScrubbingChanged: { isScrubbingElevationChart = $0 }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .toolbarBackground(.bar, for: .navigationBar, .tabBar)
        .toolbarBackground(.visible, for: .navigationBar, .tabBar)
        .alert("위치 권한이 필요합니다", isPresented: $locationTracker.showsAuthorizationDeniedAlert) {
            Button("설정 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("현재 위치를 표시하려면 설정에서 위치 접근을 허용해 주세요.")
        }
    }

    private var mapLayer: some View {
        ZStack {
            CourseMapView(
                course: course,
                selectedCueID: $selectedCueID,
                selectedProfilePoint: $selectedProfilePoint,
                trackingMode: locationTracker.mode,
                onUserStopFollowing: { [locationTracker] in
                    locationTracker.stopFollowing()
                },
                isScrubbingProfile: isScrubbingElevationChart
            )
            .ignoresSafeArea(.container, edges: [.top, .bottom])

            VStack {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        locateButton
                        elevationChartButton
                    }
                }
                Spacer()
            }
            .padding(.top, 12)
            .padding(.trailing, 12)

            VStack {
                Spacer()
                if let selectedCue {
                    SelectedCueOverlay(course: course, cue: selectedCue) {
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
    }

    private var elevationChartButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showsElevationChart.toggle()
            }
        } label: {
            Image(systemName: showsElevationChart ? "mountain.2.fill" : "mountain.2")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(showsElevationChart ? Color.accentColor : Color.primary)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color(.separator), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("고도 그래프")
        .accessibilityValue(showsElevationChart ? "표시 중" : "숨김")
    }

    private var locateButton: some View {
        Button {
            locationTracker.toggle(course: course)
        } label: {
            Image(systemName: locationTracker.mode == .following ? "location.fill" : "location")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(locationTracker.mode == .off ? Color.primary : Color.accentColor)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color(.separator), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("내 위치")
        .accessibilityValue(locateButtonAccessibilityValue)
    }

    private var locateButtonAccessibilityValue: String {
        switch locationTracker.mode {
        case .off: return "꺼짐"
        case .following: return "따라가는 중"
        case .tracking: return "위치 표시 중"
        }
    }
}

private struct CourseCueSheetTab: View {
    let course: LoadedCourse
    @Binding var selectedCueID: UUID?
    @Binding var selectedProfilePoint: CourseProfileSelection?
    let currentLocation: CourseProfileSelection?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CueSheetListView(
                        course: course,
                        selectedCueID: cueSelectionBinding,
                        selectedProfilePoint: $selectedProfilePoint,
                        currentLocation: currentLocation
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
    let course: LoadedCourse
    let cue: CourseCuePoint
    var onClose: () -> Void

    private var glyph: CuePointGlyph {
        cuePointGlyph(for: cue.pointType)
    }

    private var progress: RouteElevationProgressStats? {
        RouteElevationProgress(trackPoints: course.trackPoints)
            .stats(atDistanceKm: cue.distanceKm, trackPoints: course.trackPoints)
    }

    private var remainingDistanceKm: Double {
        max(0, course.totalDistanceKm - cue.distanceKm)
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

struct MetricTile: View {
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
              let index = cueTrackIndex(selectedCue, in: course.trackPoints) else {
            return nil
        }
        return course.trackPoints[index].ele
    }
}

struct DetailRow: View {
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
