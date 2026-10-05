import CoursePreviewCore
import SwiftUI

struct CourseViewerView: View {
    let course: LoadedCourse
    /// 파일 브라우저로 돌아간다. 내비게이션 바를 숨긴 가로 지도 화면의 뒤로가기 버튼이 쓴다.
    var onClose: () -> Void = {}

    @State private var selectedCueID: UUID?
    @State private var selectedProfilePoint: CourseProfileSelection?
    @State private var selectedTab: CourseViewerTab = .summary
    /// 큐나 지점을 선택할 때마다 증가한다. 지도는 이 값이 바뀔 때만 선택 위치로 이동한다.
    @State private var mapCenterRequest = 0
    /// 지도를 코스 전체 보기로 되돌릴 때마다 증가한다. 지도 버튼과 키보드 단축키가 함께 쓴다.
    @State private var fitCourseRequest = 0
    @AppStorage("mapShowsElevationChart") private var showsElevationChart = true
    @State private var locationTracker = CourseLocationTracker()
    /// 오르막 구간. 트랙 전체를 훑으므로 코스마다 한 번 백그라운드에서 계산한다. nil이면 계산 중.
    @State private var climbSections: (courseID: UUID, sections: [CourseClimbSection])?
    /// 넓은 화면 사이드바에 띄울 패널. 지도는 항상 옆에 보이므로 큐시트를 기본으로 둔다.
    @State private var sidebarPanel: CourseSidebarPanel = .cueSheet
    /// 탭 배치에서 시트로 띄운 구간 상세. 화면 이동으로 열면 DocumentGroup 바와 상세 화면 바가 두 줄로 쌓인다.
    @State private var presentedClimbSection: ClimbSectionRoute?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// 코스 위로 인식된 현재 위치. 코스 밖이거나 트래킹 중이 아니면 nil.
    private var currentRouteLocation: CourseProfileSelection? {
        locationTracker.currentLocation?.routeMatch
    }

    private var selectedCue: CourseCuePoint? {
        guard let selectedCueID else { return nil }
        return course.cuePoints.first { $0.id == selectedCueID }
    }

    var body: some View {
        Group {
            if usesSidebarLayout {
                sidebarLayout
            } else {
                // DocumentGroup이 바를 두므로 내비게이션 스택 없이 두고, 구간 상세는 시트로 띄운다.
                tabLayout
                    .environment(\.showClimbSectionDetail) { section in
                        presentedClimbSection = ClimbSectionRoute(section: section)
                    }
                    .sheet(item: $presentedClimbSection) { route in
                        NavigationStack {
                            ClimbSectionDetailView(course: course, section: route.section) { cue in
                                linkedCueSelection.wrappedValue = cue.id
                                selectedTab = .map
                            }
                            .navigationBarTitleDisplayMode(.inline)
                            // DocumentGroup이 시트 바에도 뒤로가기 버튼을 붙이므로 숨기고 닫기 버튼만 둔다.
                            .navigationBarBackButtonHidden(true)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("닫기", systemImage: "xmark") {
                                        presentedClimbSection = nil
                                    }
                                }
                            }
                        }
                    }
                    .toolbar {
                        if selectedTab == .cueSheet {
                            ToolbarItem(placement: .topBarTrailing) {
                                CueSheetFilterMenu()
                            }
                        }
                    }
            }
        }
        .task(id: course.id) {
            let course = course
            let detected = await Task.detached(priority: .userInitiated) {
                CourseClimbDetector.sections(in: course)
            }.value
            climbSections = (course.id, detected)
        }
        .onDisappear {
            locationTracker.stop()
        }
        .focusedSceneValue(\.courseViewerCommandHandler, commandHandler)
    }

    // MARK: - Keyboard commands

    private var commandHandler: CourseViewerCommandHandler {
        CourseViewerCommandHandler(
            selectPreviousCue: { selectAdjacentCue(forward: false) },
            selectNextCue: { selectAdjacentCue(forward: true) },
            clearSelection: {
                selectedCueID = nil
                selectedProfilePoint = nil
            },
            fitCourse: {
                showMapIfNeeded()
                locationTracker.stopFollowing()
                fitCourseRequest += 1
            },
            toggleLocation: {
                showMapIfNeeded()
                locationTracker.toggle(course: course)
            },
            toggleElevationChart: {
                showMapIfNeeded()
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsElevationChart.toggle()
                }
            },
            hasCues: !course.cuePoints.isEmpty,
            hasSelection: selectedCueID != nil || selectedProfilePoint != nil,
            showsElevationChart: showsElevationChart
        )
    }

    /// 선택한 큐(없으면 선택 지점) 앞뒤의 큐를 고른다. 아무것도 없으면 처음이나 마지막 큐.
    private func selectAdjacentCue(forward: Bool) {
        let cues = course.sortedCuePoints
        let target: CourseCuePoint?
        if let selectedCueID, let index = cues.firstIndex(where: { $0.id == selectedCueID }) {
            let adjacent = forward ? index + 1 : index - 1
            target = cues.indices.contains(adjacent) ? cues[adjacent] : nil
        } else if let km = selectedProfilePoint?.distanceKm {
            target = forward ? cues.first { $0.distanceKm > km } : cues.last { $0.distanceKm < km }
        } else {
            target = forward ? cues.first : cues.last
        }
        guard let target else { return }
        linkedCueSelection.wrappedValue = target.id
    }

    /// 탭 배치에서는 지도 조작 단축키를 누르면 결과가 보이도록 지도 탭으로 옮긴다.
    private func showMapIfNeeded() {
        if !usesSidebarLayout {
            selectedTab = .map
        }
    }

    /// iPad처럼 가로·세로 모두 넉넉하면 탭 대신 사이드바와 지도를 함께 보여준다.
    /// 큰 iPhone 가로 모드도 가로는 regular지만 세로가 낮아 기존 탭 배치를 쓴다.
    private var usesSidebarLayout: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    // MARK: - Sidebar layout

    private var sidebarLayout: some View {
        GeometryReader { proxy in
            HStack(spacing: 0) {
                // 상세 화면은 사이드바 스택 안에서 열려 지도가 계속 옆에 보인다.
                // 루트는 DocumentGroup 바와 겹치지 않게 자기 바를 숨긴다.
                NavigationStack {
                    sidebar
                        .toolbar(.hidden, for: .navigationBar)
                }
                .frame(width: Self.sidebarWidth(forTotalWidth: proxy.size.width))

                Divider()
                    .ignoresSafeArea()

                mapTab(isRegularWidth: true)
            }
        }
    }

    /// 지도 폭을 넉넉히 남기도록 화면의 38% 안팎으로 잡되 큐 행이 읽히는 폭은 지킨다.
    private static func sidebarWidth(forTotalWidth width: CGFloat) -> CGFloat {
        min(400, max(320, width * 0.38))
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("보기", selection: $sidebarPanel) {
                    ForEach(CourseSidebarPanel.allCases) { panel in
                        Text(panel.title).tag(panel)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if sidebarPanel == .cueSheet {
                    CueSheetFilterMenu()
                        .labelStyle(.iconOnly)
                        .font(.title3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            switch sidebarPanel {
            case .summary:
                summaryTab
            case .cueSheet:
                cueSheetTab
            }
        }
        .background(Color(.systemGroupedBackground))
        // 지도가 이미 옆에 있으므로 선택만 바꾸면 지도가 그 큐로 이동한다.
        .climbSectionDestination(course: course) { cue in
            linkedCueSelection.wrappedValue = cue.id
        }
    }

    // MARK: - Tab layout

    private var summaryTab: some View {
        CourseSummaryTab(
            course: course,
            selectedCue: selectedCue,
            selectedProfilePoint: selectedProfilePoint
        )
    }

    private func mapTab(isRegularWidth: Bool) -> some View {
        CourseMapTab(
            course: course,
            selectedCueID: linkedCueSelection,
            selectedProfilePoint: linkedProfileSelection,
            locationTracker: locationTracker,
            mapCenterRequest: mapCenterRequest,
            fitCourseRequest: $fitCourseRequest,
            isRegularWidth: isRegularWidth,
            onClose: onClose
        )
    }

    private var cueSheetTab: some View {
        CourseCueSheetTab(
            course: course,
            climbSections: currentClimbSections,
            selectedCueID: linkedCueSelection,
            selectedProfilePoint: linkedProfileSelection,
            currentLocation: currentRouteLocation
        )
    }

    private var tabLayout: some View {
        TabView(selection: $selectedTab) {
            summaryTab
                .tabItem {
                    Label("요약", systemImage: "chart.bar.doc.horizontal")
                }
                .tag(CourseViewerTab.summary)

            mapTab(isRegularWidth: false)
                .tabItem {
                    Label("지도", systemImage: "map")
                }
                .tag(CourseViewerTab.map)

            cueSheetTab
                .tabItem {
                    Label("큐시트", systemImage: "list.bullet.rectangle")
                }
                .tag(CourseViewerTab.cueSheet)
        }
    }

    private var currentClimbSections: [CourseClimbSection]? {
        guard let climbSections, climbSections.courseID == course.id else { return nil }
        return climbSections.sections
    }

    private var linkedCueSelection: Binding<UUID?> {
        Binding {
            selectedCueID
        } set: { id in
            if id != nil {
                selectedProfilePoint = nil
                mapCenterRequest += 1
            }
            selectedCueID = id
        }
    }

    private var linkedProfileSelection: Binding<CourseProfileSelection?> {
        Binding {
            selectedProfilePoint
        } set: { selection in
            if selection != nil {
                mapCenterRequest += 1
            }
            selectedProfilePoint = selection
        }
    }
}

private enum CourseViewerTab: Hashable {
    case summary
    case map
    case cueSheet
}

private enum CourseSidebarPanel: CaseIterable, Identifiable {
    case summary
    case cueSheet

    var id: Self { self }

    var title: String {
        switch self {
        case .summary: return "요약"
        case .cueSheet: return "큐시트"
        }
    }
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
            // 큰 iPhone 가로 모드처럼 넓은 화면에서도 행이 끝없이 늘어나지 않게 읽기 좋은 폭으로 가운데 둔다.
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
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
    let mapCenterRequest: Int
    @Binding var fitCourseRequest: Int
    /// iPad 사이드바 배치. 지도 폭이 넓어 선택 카드를 좁게 둔다.
    var isRegularWidth = false
    var onClose: () -> Void
    @AppStorage("mapShowsElevationChart") private var showsElevationChart = true
    @AppStorage(CourseMapStyle.storageKey) private var mapStyle: CourseMapStyle = .standard
    @State private var compassLink = CourseMapCompassLink()
    @State private var isScrubbingElevationChart = false
    /// 트랙 포인트 전체를 훑어 만들기 때문에 코스마다 한 번만 계산해 둔다.
    @State private var cachedElevationProgress: (courseID: UUID, progress: RouteElevationProgress)?
    @Environment(\.openURL) private var openURL
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var selectedCue: CourseCuePoint? {
        guard let selectedCueID else { return nil }
        return course.cuePoints.first { $0.id == selectedCueID }
    }

    /// iPhone 가로 모드. 그래프와 선택 카드를 낮게 그리고 내비게이션 바 대신 뒤로가기 버튼을 띄운다.
    private var isCompactHeight: Bool {
        verticalSizeClass == .compact
    }

    var body: some View {
        // 고도 그래프는 지도 위에 떠 있는 카드다. safeAreaInset으로 넣어 지도는 그 뒤까지 깔리고,
        // 지도 위 버튼과 선택 카드, 센터링 기준 영역은 그래프 위로 올라가게 한다.
        mapLayer
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsElevationChart {
                    elevationChart
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarBackground(.bar, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
            .onChange(of: course.id, initial: true) { _, id in
                cachedElevationProgress = (id, RouteElevationProgress(trackPoints: course.trackPoints))
            }
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

    private var elevationChart: some View {
        MapElevationChartView(
            course: course,
            selectedCueID: $selectedCueID,
            selectedProfilePoint: $selectedProfilePoint,
            currentLocation: locationTracker.currentLocation?.routeMatch,
            isOffRoute: locationTracker.isOffRoute,
            lastRouteLocation: locationTracker.lastRouteMatch,
            onScrubbingChanged: { isScrubbingElevationChart = $0 },
            isCompact: isCompactHeight
        )
    }

    private var elevationProgress: RouteElevationProgress {
        if let cachedElevationProgress, cachedElevationProgress.courseID == course.id {
            return cachedElevationProgress.progress
        }
        return RouteElevationProgress(trackPoints: course.trackPoints)
    }

    private func progressStats(atDistanceKm distanceKm: Double) -> RouteElevationProgressStats? {
        elevationProgress.stats(atDistanceKm: distanceKm, trackPoints: course.trackPoints)
    }

    private var mapLayer: some View {
        ZStack {
            // 지도는 화면 끝까지 깔고, 내비게이션 바·그래프 카드·탭 바에 가려지는 폭은 safe area로 받아 넘긴다.
            GeometryReader { proxy in
                CourseMapView(
                    course: course,
                    selectedCueID: $selectedCueID,
                    selectedProfilePoint: $selectedProfilePoint,
                    trackingMode: locationTracker.mode,
                    onUserStopFollowing: { [locationTracker] in
                        locationTracker.stopFollowing()
                    },
                    isScrubbingProfile: isScrubbingElevationChart,
                    centerRequest: mapCenterRequest,
                    obscuredInsets: proxy.safeAreaInsets,
                    mapStyle: mapStyle,
                    fitCourseRequest: fitCourseRequest,
                    compassLink: compassLink
                )
                // GeometryReader 자체는 safe area 안에 두어야 proxy가 가려지는 폭을 알려 준다.
                .ignoresSafeArea(.container)
            }

            VStack {
                HStack(alignment: .top) {
                    if isCompactHeight {
                        backButton
                    }
                    Spacer()
                    VStack(spacing: 8) {
                        VStack(spacing: 0) {
                            locateButton
                            Divider()
                                .frame(width: 28)
                            fitCourseButton
                        }
                        .floatingCapsuleBackground()
                        mapStyleButton
                        elevationChartButton
                        // 회전하지 않았을 때는 숨어 있으므로 맨 아래에 두어 빈자리가 보이지 않게 한다.
                        CourseMapCompassButton(link: compassLink)
                            .frame(width: 44, height: 44)
                    }
                }
                Spacer()
            }
            .padding(.top, 12)
            .padding(.horizontal, 12)

            VStack {
                Spacer()
                selectionOverlay
                    // 가로 모드와 iPad는 폭이 남으므로 카드를 왼쪽에 좁게 두어 지도 중앙을 가리지 않는다.
                    .frame(maxWidth: isCompactHeight || isRegularWidth ? 520 : .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, isCompactHeight ? 10 : 16)
            }
        }
    }

    @ViewBuilder
    private var selectionOverlay: some View {
        if let selectedCue {
            SelectedCueOverlay(
                course: course,
                cue: selectedCue,
                progress: progressStats(atDistanceKm: selectedCue.distanceKm),
                isCompact: isCompactHeight
            ) {
                selectedCueID = nil
            }
        } else if let profilePoint = selectedProfilePoint {
            SelectedProfilePointOverlay(
                course: course,
                selection: profilePoint,
                progress: progressStats(atDistanceKm: profilePoint.distanceKm),
                isCompact: isCompactHeight
            ) {
                selectedProfilePoint = nil
            }
        }
    }

    private var backButton: some View {
        Button(action: onClose) {
            Image(systemName: "chevron.backward")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
                .floatingCircleBackground()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("파일 브라우저로 돌아가기")
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
                .floatingCircleBackground()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("고도 그래프")
        .accessibilityValue(showsElevationChart ? "표시 중" : "숨김")
    }

    private var mapStyleButton: some View {
        Menu {
            Picker("지도 종류", selection: $mapStyle) {
                ForEach(CourseMapStyle.allCases) { style in
                    Label(style.label, systemImage: style.symbol)
                        .tag(style)
                }
            }
        } label: {
            Image(systemName: mapStyle.symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
                .floatingCircleBackground()
        }
        .buttonStyle(.plain)
        .accessibilityLabel("지도 종류")
        .accessibilityValue(mapStyle.label)
    }

    private var fitCourseButton: some View {
        Button {
            locationTracker.stopFollowing()
            fitCourseRequest += 1
        } label: {
            Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("코스 전체 보기")
    }

    private var locateButton: some View {
        Button {
            locationTracker.toggle(course: course)
        } label: {
            Image(systemName: locationTracker.mode == .following ? "location.fill" : "location")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(locationTracker.mode == .off ? Color.primary : Color.accentColor)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
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
    let climbSections: [CourseClimbSection]?
    @Binding var selectedCueID: UUID?
    @Binding var selectedProfilePoint: CourseProfileSelection?
    let currentLocation: CourseProfileSelection?
    /// true면 구간을 이루는 큐를 구간 행으로 묶어 보여주고, false면 큐를 모두 그대로 보여준다.
    @AppStorage("cueSheetGroupsClimbSections") private var groupsClimbSections = true
    @AppStorage("cueSheetClimbsOnly") private var climbsOnly = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(countText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.horizontal, 4)

                    CueSheetListView(
                        course: course,
                        selectedCueID: cueSelectionBinding,
                        selectedProfilePoint: $selectedProfilePoint,
                        currentLocation: currentLocation,
                        climbSections: climbSections,
                        groupsClimbSections: groupsClimbSections,
                        climbsOnly: climbsOnly
                    )
                }
                .padding(16)
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: selectedCueID) { _, id in
                guard let id else { return }
                let rowID = CueSheetListView.rowID(
                    forCueID: id,
                    sections: climbSections,
                    groupsClimbSections: groupsClimbSections
                )
                withAnimation(.easeInOut(duration: 0.25)) {
                    proxy.scrollTo(rowID, anchor: .center)
                }
            }
            // 코스 앞부분에 구간이 없으면 보기를 바꿔도 화면에 보이는 행이 그대로라 바뀐 걸 알 수 없다.
            // 보기를 바꾸면 첫 오르막 구간으로 스크롤해 바뀐 부분을 바로 보여준다.
            .onChange(of: groupsClimbSections) {
                scrollToFirstClimb(proxy)
            }
            .onChange(of: climbsOnly) {
                scrollToFirstClimb(proxy)
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

    private func scrollToFirstClimb(_ proxy: ScrollViewProxy) {
        let candidates = climbsOnly ? climbSections?.filter { !$0.isDownhill } : climbSections
        guard let first = candidates?.min(by: { $0.startKm < $1.startKm }) else { return }
        let rowID = CueSheetListView.rowID(
            forCueID: first.startCue.id,
            sections: climbSections,
            groupsClimbSections: groupsClimbSections
        )
        // 바뀐 리스트가 그려진 다음에 스크롤해야 새 행을 찾는다.
        Task { @MainActor in
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(rowID, anchor: .top)
            }
        }
    }

    private var countText: String {
        guard let climbSections else { return "큐 \(course.cuePoints.count)개" }
        if climbsOnly {
            return "오르막 \(climbSections.filter { !$0.isDownhill }.count)개"
        }
        if groupsClimbSections {
            return "구간 \(climbSections.count)개"
        }
        return "큐 \(course.cuePoints.count)개"
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

/// 큐시트 탭 내비게이션 바 오른쪽의 보기·필터 메뉴. 탭 안의 toolbar는 바깥 내비게이션 바에 붙지 않아
/// 뷰어가 큐시트 탭일 때 직접 띄우고, 설정은 큐시트 탭과 같은 AppStorage 키로 공유한다.
private struct CueSheetFilterMenu: View {
    @AppStorage("cueSheetGroupsClimbSections") private var groupsClimbSections = true
    @AppStorage("cueSheetClimbsOnly") private var climbsOnly = false

    /// 기본 보기(구간 보기, 오르막만 끔)에서 바뀌었는지. 바뀌면 필터 아이콘을 채워 표시한다.
    private var isFilterActive: Bool {
        climbsOnly || !groupsClimbSections
    }

    var body: some View {
        Menu {
            Picker("보기", selection: animatedBinding($groupsClimbSections)) {
                Label("구간 보기", systemImage: "rectangle.stack").tag(true)
                Label("큐 전체 보기", systemImage: "list.bullet").tag(false)
            }

            Section {
                Toggle(isOn: animatedBinding($climbsOnly)) {
                    Label("오르막만", systemImage: "mountain.2")
                }
            }
        } label: {
            Label(
                "필터",
                systemImage: isFilterActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .accessibilityValue(isFilterActive ? "적용됨" : "기본")
    }

    private func animatedBinding(_ binding: Binding<Bool>) -> Binding<Bool> {
        Binding {
            binding.wrappedValue
        } set: { value in
            withAnimation(.easeInOut(duration: 0.2)) {
                binding.wrappedValue = value
            }
        }
    }
}

private struct SelectedCueOverlay: View {
    let course: LoadedCourse
    let cue: CourseCuePoint
    let progress: RouteElevationProgressStats?
    var isCompact = false
    var onClose: () -> Void

    private var remainingDistanceKm: Double {
        max(0, course.totalDistanceKm - cue.distanceKm)
    }

    var body: some View {
        SelectedPointCard(
            detail: "누적 상승 \(formatRouteElevation(progress?.ascentFromStart)) · 남은 \(formatRouteDistance(remainingDistanceKm)) · 남은 상승 \(formatRouteElevation(progress?.ascentToEnd))",
            isCompact: isCompact,
            onClose: onClose
        )
    }
}

private struct SelectedProfilePointOverlay: View {
    let course: LoadedCourse
    let selection: CourseProfileSelection
    let progress: RouteElevationProgressStats?
    var isCompact = false
    var onClose: () -> Void

    private var remainingDistanceKm: Double {
        max(0, course.totalDistanceKm - selection.distanceKm)
    }

    var body: some View {
        SelectedPointCard(
            detail: "누적 상승 \(formatRouteElevation(progress?.ascentFromStart)) · 남은 \(formatRouteDistance(remainingDistanceKm)) · 남은 상승 \(formatRouteElevation(progress?.ascentToEnd))",
            isCompact: isCompact,
            onClose: onClose
        )
    }
}

/// 지도 하단 선택 카드. 선택 지점의 이름과 종류는 지도 핀 말풍선에 나오므로 진행 수치만 한 줄로 그린다.
private struct SelectedPointCard: View {
    let detail: String
    let isCompact: Bool
    var onClose: () -> Void

    var body: some View {
        HStack(spacing: isCompact ? 10 : 12) {
            Text(detail)
                .font(isCompact ? .caption : .subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            Spacer(minLength: 0)

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("선택 해제")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, isCompact ? 8 : 12)
        .floatingCardBackground(cornerRadius: isCompact ? 16 : 20)
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
                progressRows(atDistanceKm: selectedCue.distanceKm)
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
                progressRows(atDistanceKm: selectedProfilePoint.distanceKm)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    /// 선택 위치 기준 출발점부터의 누적 상승·하강과 종료점까지 남은 거리·상승·하강.
    @ViewBuilder
    private func progressRows(atDistanceKm distanceKm: Double) -> some View {
        // 왕복·루프 코스에서도 맞도록 좌표가 아니라 누적 거리로 트랙 위치를 찾는다.
        let stats = RouteElevationProgress(trackPoints: course.trackPoints)
            .stats(atDistanceKm: distanceKm, trackPoints: course.trackPoints)
        DetailRow(title: "누적 상승", value: formatRouteElevation(stats?.ascentFromStart))
        DetailRow(title: "누적 하강", value: formatRouteElevation(stats?.descentFromStart))
        DetailRow(title: "남은 거리", value: formatRouteDistance(max(0, course.totalDistanceKm - distanceKm)))
        DetailRow(title: "남은 상승", value: formatRouteElevation(stats?.ascentToEnd))
        DetailRow(title: "남은 하강", value: formatRouteElevation(stats?.descentToEnd))
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

/// 탭 배치에서 구간 상세를 sheet(item:)로 띄우기 위한 식별자.
extension ClimbSectionRoute: Identifiable {
    var id: UUID { section.id }
}
