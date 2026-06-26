import SwiftUI

struct CourseViewerView: View {
    let course: LoadedCourse
    var onOpenFile: () -> Void

    @State private var selectedCueID: UUID?

    private var selectedCue: CourseCuePoint? {
        guard let selectedCueID else { return nil }
        return course.cuePoints.first { $0.id == selectedCueID }
    }

    var body: some View {
        TabView {
            CourseSummaryTab(
                course: course,
                selectedCue: selectedCue,
                onOpenFile: onOpenFile
            )
            .tabItem {
                Label("요약", systemImage: "chart.bar.doc.horizontal")
            }

            CourseMapTab(course: course, selectedCueID: $selectedCueID)
                .tabItem {
                    Label("지도", systemImage: "map")
                }

            CourseElevationTab(course: course, selectedCueID: selectedCueID)
                .tabItem {
                    Label("고도그래프", systemImage: "mountain.2")
                }

            CourseCueSheetTab(course: course, selectedCueID: $selectedCueID)
                .tabItem {
                    Label("큐시트", systemImage: "list.bullet.rectangle")
                }
        }
    }
}

private struct CourseSummaryTab: View {
    let course: LoadedCourse
    let selectedCue: CourseCuePoint?
    var onOpenFile: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CourseHeaderView(course: course, onOpenFile: onOpenFile)
                CourseSummaryGrid(course: course)
                ViewerSection(title: "상세 정보", systemImage: "info.circle") {
                    CourseDetailRows(course: course, selectedCue: selectedCue)
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

    private var selectedCue: CourseCuePoint? {
        guard let selectedCueID else { return nil }
        return course.cuePoints.first { $0.id == selectedCueID }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            CourseMapView(course: course, selectedCueID: $selectedCueID)

            if let selectedCue {
                SelectedCueOverlay(cue: selectedCue) {
                    selectedCueID = nil
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
    }
}

private struct CourseElevationTab: View {
    let course: LoadedCourse
    let selectedCueID: UUID?

    @State private var distanceScale: ElevationProfileScaleOption = .standard
    @State private var elevationScale: ElevationProfileScaleOption = .standard
    @State private var horizontalScrollPosition = 0.0
    @State private var fitAllEnabled = false

    var body: some View {
        GeometryReader { proxy in
            let viewportSize = proxy.size
            let profileScale = profileScale(for: viewportSize)
            let profileSize = ElevationProfileView.preferredSize(
                trackPoints: course.trackPoints,
                availableWidth: viewportSize.width,
                scale: profileScale
            )
            let viewportWidth = max(1, viewportSize.width)
            let maxHorizontalOffset = max(0, profileSize.width - viewportWidth)
            let horizontalOffset = maxHorizontalOffset * CGFloat(horizontalScrollPosition)
            let renderWidth = max(profileSize.width, viewportWidth)

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    scaleMenu
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                ElevationProfileHeaderView(
                    trackPoints: course.trackPoints,
                    width: renderWidth,
                    contentWidth: profileSize.width,
                    visibleWidth: viewportWidth,
                    horizontalOffset: horizontalOffset
                )

                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        ElevationProfileView(
                            trackPoints: course.trackPoints,
                            cuePoints: course.sortedCuePoints,
                            selectedCueID: selectedCueID,
                            contentWidth: profileSize.width,
                            visibleWidth: viewportWidth,
                            horizontalOffset: horizontalOffset
                        )
                        .frame(width: renderWidth, height: profileSize.height)
                        .offset(x: -horizontalOffset)
                    }
                    .frame(width: viewportWidth, height: profileSize.height, alignment: .topLeading)
                    .clipped()
                    .padding(.vertical, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

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

    private func profileScale(for viewportSize: CGSize) -> ElevationProfileScale {
        if fitAllEnabled {
            return ElevationProfileView.fittingScale(
                trackPoints: course.trackPoints,
                availableWidth: viewportSize.width,
                availableHeight: graphViewportHeight(in: viewportSize)
            )
        }

        return ElevationProfileScale(
            distanceFactor: distanceScale.factor,
            elevationFactor: elevationScale.factor
        )
    }

    private func graphViewportHeight(in viewportSize: CGSize) -> CGFloat {
        max(
            1,
            viewportSize.height
                - Self.scaleToolbarHeight
                - ElevationProfileView.headerHeight
                - Self.graphVerticalPadding
        )
    }

    private var distanceScaleBinding: Binding<ElevationProfileScaleOption> {
        Binding {
            distanceScale
        } set: { option in
            distanceScale = option
            fitAllEnabled = false
        }
    }

    private var elevationScaleBinding: Binding<ElevationProfileScaleOption> {
        Binding {
            elevationScale
        } set: { option in
            elevationScale = option
            fitAllEnabled = false
        }
    }

    private var scaleMenu: some View {
        Menu {
            Button {
                fitAllEnabled = true
                horizontalScrollPosition = 0
            } label: {
                Label("전체보기", systemImage: fitAllEnabled ? "checkmark" : "rectangle.expand.vertical")
            }

            Section("거리") {
                Picker("거리", selection: distanceScaleBinding) {
                    ForEach(ElevationProfileScaleOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            }

            Section("고도") {
                Picker("고도", selection: elevationScaleBinding) {
                    ForEach(ElevationProfileScaleOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
            }

            Button {
                distanceScale = .standard
                elevationScale = .standard
                horizontalScrollPosition = 0
                fitAllEnabled = false
            } label: {
                Label("기본값", systemImage: "arrow.counterclockwise")
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.body.weight(.semibold))
                .frame(width: 34, height: 30)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("스케일 조정")
    }

    private static let scaleToolbarHeight: CGFloat = 46
    private static let graphVerticalPadding: CGFloat = 24
}

private enum ElevationProfileScaleOption: Double, CaseIterable, Identifiable {
    case ten = 0.1
    case quarter = 0.25
    case half = 0.5
    case standard = 1
    case expanded = 1.5
    case detailed = 2

    var id: Double { rawValue }

    var factor: CGFloat {
        CGFloat(rawValue) * ElevationProfileScale.standardFactor
    }

    var title: String {
        "\(Int(rawValue * 100))%"
    }
}

private struct CourseCueSheetTab: View {
    let course: LoadedCourse
    @Binding var selectedCueID: UUID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CueSheetListView(course: course, selectedCueID: $selectedCueID)
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

private struct CourseHeaderView: View {
    let course: LoadedCourse
    var onOpenFile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
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

                Spacer()

                Button(action: onOpenFile) {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("다른 파일 열기")
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
    let selectedCue: CourseCuePoint?

    var body: some View {
        VStack(spacing: 0) {
            detailRow("파일", value: course.sourceURL.lastPathComponent)
            detailRow("형식", value: course.fileKind.rawValue)
            detailRow("트랙 포인트", value: "\(course.trackPoints.count)")
            detailRow("경유지", value: "\(course.routePoints.count)")
            detailRow("큐시트", value: "\(course.cuePoints.count)")
            detailRow("최저 고도", value: formatRouteElevation(course.elevationStats.min))
            detailRow("최고 고도", value: formatRouteElevation(course.elevationStats.max))
            detailRow("누적 하강", value: formatRouteElevation(course.elevationStats.descent))
            if let selectedCue {
                detailRow("선택한 큐", value: selectedCue.displayName)
                detailRow("선택 위치", value: formatRouteDistance(selectedCue.distanceKm))
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private func detailRow(_ title: String, value: String) -> some View {
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
