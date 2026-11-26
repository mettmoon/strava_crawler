import SwiftUI
import MapKit
import CourseBoyKit
import CourseBoyMapFile

// MARK: - CuePoint 타입 목록

/// TCX PointType 값(저장용)과 한글 표시 이름 쌍.
let cuePointTypes: [(value: String, label: String)] = [
    ("Generic",        "일반 지점"),
    ("Summit",         "정상"),
    ("Valley",         "계곡"),
    ("Water",          "급수대"),
    ("Food",           "보급소"),
    ("Danger",         "위험 구간"),
    ("Left",           "좌회전"),
    ("Right",          "우회전"),
    ("Straight",       "직진"),
    ("First Aid",      "응급 의료"),
    ("4th Category",   "4등급 오르막"),
    ("3rd Category",   "3등급 오르막"),
    ("2nd Category",   "2등급 오르막"),
    ("1st Category",   "1등급 오르막"),
    ("Hors Category",  "HC급 오르막"),
    ("Sprint",         "스프린트 구간"),
]

func cuePointLabel(for value: String) -> String {
    cuePointTypes.first { $0.value == value }?.label ?? "알수없음(\(value))"
}

private func cuePointPickerTypes(for value: String) -> [(value: String, label: String)] {
    guard !cuePointTypes.contains(where: { $0.value == value }) else { return cuePointTypes }
    return cuePointTypes + [(value, cuePointLabel(for: value))]
}

struct CuePointGlyph {
    var symbol: String? = nil   // SF Symbol (nil이면 text 사용)
    var text: String? = nil     // glyphText
    var color: NSColor
}

func cuePointGlyph(for value: String) -> CuePointGlyph {
    switch value {
    case "Summit":          return .init(symbol: "mountain.2.fill",              color: .systemGreen)
    case "Valley":          return .init(symbol: "arrow.down.to.line",           color: .systemTeal)
    case "Water":           return .init(symbol: "drop.fill",                    color: .systemBlue)
    case "Food":            return .init(symbol: "fork.knife",                   color: .systemOrange)
    case "Danger":          return .init(symbol: "exclamationmark.triangle.fill", color: .systemRed)
    case "Left":            return .init(symbol: "arrow.turn.up.left",           color: .systemPurple)
    case "Right":           return .init(symbol: "arrow.turn.up.right",          color: .systemPurple)
    case "Straight":        return .init(symbol: "arrow.up",                     color: .systemGray)
    case "First Aid":       return .init(symbol: "cross.fill",                   color: .systemRed)
    case "1st Category":   return .init(text: "1",  color: .systemYellow)
    case "2nd Category":   return .init(text: "2",  color: .systemYellow)
    case "3rd Category":   return .init(text: "3",  color: .systemYellow)
    case "4th Category":   return .init(text: "4",  color: .systemYellow)
    case "Hors Category":   return .init(text: "HC", color: .systemRed)
    case "Sprint":          return .init(symbol: "bolt.fill",                    color: .systemYellow)
    default:                return .init(symbol: "mappin",                       color: .systemOrange)
    }
}

// MARK: - CourseEditorView

/// 코스 편집 화면.
/// draft(로컬 복사본)에서 작업하다가 "저장"으로 CourseRecord에 커밋, "취소"로 폐기.
struct CourseEditorView: View {
    @ObservedObject var course: CourseRecord
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var draft: CourseEditorDraft
    @State private var isCalculating = false
    @State private var showDiscardConfirm = false
    @State private var closeConfirmed = false
    @State private var hoverInfo: RouteHoverInfo?
    @State private var selectedCueID: UUID?
    @State private var editingCueID: UUID?
    @State private var rangeSelection: ChartRangeSelection?
    @State private var pinnedDistanceKm: Double?
    @State private var isInspectorPresented = true
    /// 증가시키면 고도 그래프·지도가 전체 보기로 돌아간다.
    @State private var zoomResetToken = 0

    // 카카오 검색
    @State private var searchQuery = ""
    @State private var searchResults: [KakaoLocalResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var mapViewRef: MKMapView?   // 맵 뷰 직접 참조 (검색 시 visible rect 조회용)

    @AppStorage(MapStyleStorageKey.editor) private var mapStyleRaw: String = MapStyleOption.standard.rawValue
    @AppStorage(RouteProfileStorageKey.editor) private var routeProfileRaw: String = OSRMRouteProfile.defaultProfile.rawValue
    /// 경로 색은 보기 화면과 같은 설정을 쓴다.
    @AppStorage(RouteColorMode.storageKey) private var routeColorRaw: String = RouteColorMode.section.rawValue
    /// 설정에서 고른 지도 파일로 구한 코스 전체의 노면. 노면 소스가 없으면 nil.
    @State private var surfaceStatus: CourseSurfaceStatus?
    @State private var elevationFillStatus: ElevationFillStatus?

    private var routeColor: Binding<RouteColorMode> {
        Binding(
            get: { RouteColorMode(rawValue: routeColorRaw) ?? .section },
            set: { routeColorRaw = $0.rawValue }
        )
    }

    /// 실제로 칠할 방식. 노면을 골랐어도 노면 정보가 없으면 섹션 색으로 칠한다.
    private var effectiveRouteColor: RouteColorMode {
        let mode = routeColor.wrappedValue
        return mode == .surface && surfaceStatus?.analysis == nil ? .section : mode
    }

    private var mapStyle: Binding<MapStyleOption> {
        Binding(
            get: { MapStyleOption(rawValue: mapStyleRaw) ?? .standard },
            set: { mapStyleRaw = $0.rawValue }
        )
    }

    private var routeProfile: Binding<OSRMRouteProfile> {
        Binding(
            get: { OSRMRouteProfile(rawValue: routeProfileRaw) ?? .defaultProfile },
            set: { routeProfileRaw = $0.rawValue }
        )
    }

    init(course: CourseRecord, onSave: (() -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        self.course = course
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: CourseEditorDraft(from: course))
    }

    var body: some View {
        // 좌(사이드바)·우(인스펙터)를 같은 단계에 두어 둘 다 창 전체 높이 패널로 접히게 한다.
        // 상단 도구는 창 툴바가 맡고, 가운데 컬럼에는 지도와 고도표만 남긴다.
        NavigationSplitView {
            CourseEditorCuesheetSidebar(
                draft: draft,
                selectedCueID: $selectedCueID,
                pinnedDistanceKm: $pinnedDistanceKm,
                onEditCue: { editingCueID = $0 }
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            // 편집 도구와 장소 검색은 지도에 딸린 것이라 가운데 컬럼의 툴바 구역에 둔다.
            // 그래야 좌우 패널을 접고 펴도 자리가 패널을 따라 옮겨 다니지 않는다.
            detailPane
                .toolbar { editorToolbar }
        }
        .inspector(isPresented: $isInspectorPresented) {
            inspectorPane
                .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
                .toolbar {
                    // 인스펙터 접기 버튼은 인스펙터 쪽 툴바 끝에 둔다(사이드바 접기 버튼과 대칭).
                    Spacer()
                    InspectorToggleButton(isPresented: $isInspectorPresented)
                }
        }
        .onChange(of: draft.cuePoints.map(\.id)) { _, ids in
            if let sel = selectedCueID, !ids.contains(sel) {
                selectedCueID = nil
            }
            if let editing = editingCueID, !ids.contains(editing) {
                editingCueID = nil
            }
        }
        .onChange(of: draft.selectedSectionID) {
            selectedCueID = nil
            editingCueID = nil
        }
        .onChange(of: draft.sections.map(\.id)) {
            rangeSelection = nil
            pinnedDistanceKm = nil
        }
        .onChange(of: draft.sections.map(\.distanceKm)) {
            rangeSelection = nil
            pinnedDistanceKm = nil
        }
        .onChange(of: draft.sections.map(\.isHidden)) {
            // 가림 상태가 바뀌면 코스 누적 거리가 달라지므로 거리 기반 선택을 비운다.
            rangeSelection = nil
            pinnedDistanceKm = nil
        }
        // ESC는 편집기를 닫지 않고, 구간 선택이 있을 때만 해제한다.
        .onEscapeKey(isEnabled: rangeSelection != nil) { clearRangeSelection() }
        .task(id: CourseSurfaceTaskKey(trackPoints: draft.allCourseTrackPoints)) {
            await loadSurface()
        }
        .task(id: draft.elevationFillKey) {
            await fillMissingElevations()
        }
        .focusedSceneValue(\.courseFileCommandHandler, CourseFileCommandHandler(
            exportTCX: { saveDraftTCX() },
            exportGPX: { saveDraftGPX() },
            canExport: !draft.allCourseTrackPoints.isEmpty && draft.hasValidTitle
        ))
        .confirmationDialog("변경 사항을 버리시겠습니까?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("변경 사항 버리기", role: .destructive) { closeConfirmed = true }
            Button("계속 편집", role: .cancel) {}
        } message: {
            Text("저장하지 않은 변경 사항은 모두 사라집니다.")
        }
        .onChange(of: closeConfirmed) { _, confirmed in
            if confirmed {
                closeEditor()
            }
        }
        .sheet(isPresented: Binding(
            get: { editingCueID != nil },
            set: { if !$0 { editingCueID = nil } }
        )) {
            if let cueID = editingCueID,
               let cue = draft.cuePoints.first(where: { $0.id == cueID }) {
                CuePointEditSheet(
                    cue: cue,
                    trackPoints: draft.allTrackPoints,
                    onSave: { updated in
                        draft.updateCuePoint(updated)
                        selectedCueID = updated.id
                        rangeSelection = nil
                        editingCueID = nil
                    },
                    onCancel: {
                        editingCueID = nil
                    }
                )
            } else {
                ContentUnavailableView("큐시트 항목을 찾을 수 없음", systemImage: "mappin")
                    .frame(width: 360, height: 220)
            }
        }
    }

    // MARK: - 가운데 컨텐츠 (지도 + 고도그래프)

    private var selectedSectionMapRange: ChartRangeSelection? {
        guard let rangeSelection,
              sectionIndex(containing: rangeSelection) == draft.selectedSectionIndex else { return nil }
        let start = draft.selectedSectionCourseStartKm
        return ChartRangeSelection(
            startKm: rangeSelection.startKm - start,
            endKm: rangeSelection.endKm - start,
            isDragging: rangeSelection.isDragging
        )
    }

    /// 사용자가 구간 선택을 해제(ESC·해제 버튼)하면 그래프·지도를 전체 보기로 되돌린다.
    private func clearRangeSelection() {
        rangeSelection = nil
        zoomResetToken += 1
    }

    private func sectionIndex(containing range: ChartRangeSelection) -> Int? {
        guard range.lengthKm > 0 else { return nil }
        let epsilon = min(0.000_001, range.lengthKm / 2)
        let startIndex = draft.sectionIndex(
            containingCourseDistanceKm: range.lowerKm + epsilon
        )
        let endIndex = draft.sectionIndex(
            containingCourseDistanceKm: range.upperKm - epsilon
        )
        return startIndex == endIndex ? startIndex : nil
    }

    // MARK: - 우측 인스펙터

    @ViewBuilder
    private var inspectorPane: some View {
        if rangeSelection != nil || pinnedDistanceKm != nil {
            VStack(spacing: 0) {
                SelectionInspectorStack(
                    trackPoints: draft.allCourseTrackPoints,
                    rangeSelection: rangeSelection,
                    pinnedDistanceKm: pinnedDistanceKm,
                    onClearRange: { clearRangeSelection() },
                    onClearPin: { pinnedDistanceKm = nil }
                )
                if let range = rangeSelection {
                    Divider()
                    Button {
                        addSegmentFromRange(range)
                    } label: {
                        Label("구간 추가", systemImage: "flag.checkered")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(
                        range.lengthKm <= 0 || range.isDragging
                            || sectionIndex(containing: range) == nil
                    )
                    .padding(12)
                }
            }
        } else {
            CourseEditorCueInspectorView(
                course: course,
                draft: draft,
                selectedCueID: selectedCueID,
                onEditCue: { editingCueID = $0 }
            )
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        VSplitView {
            ZStack(alignment: .topTrailing) {
                CourseEditMapView(
                    draft: draft,
                    isCalculating: $isCalculating,
                    searchResults: $searchResults,
                    mapViewRef: $mapViewRef,
                    selectedCueID: selectedCueID,
                    rangeSelection: selectedSectionMapRange,
                    cameraRangeSelection: rangeSelection,
                    zoomResetToken: zoomResetToken,
                    hoverInfo: $hoverInfo,
                    pinnedDistanceKm: pinnedDistanceKm,
                    mapStyle: mapStyle.wrappedValue,
                    tileSource: MapFileStore.shared.displayTileSource,
                    routeColorMode: effectiveRouteColor,
                    unpavedRuns: effectiveRouteColor == .surface ? surfaceStatus?.analysis?.unpavedRuns : nil,
                    routingProfile: routeProfile.wrappedValue,
                    onSelectCue: { selectedCueID = $0 },
                    onDeselectFocus: { selectedCueID = nil },
                    onSearchInVisibleRect: { rect in
                        performSearch(in: rect)
                    },
                    onPinDistance: { km in
                        pinnedDistanceKm = draft.courseDistanceKm(
                            forSelectedSectionLocalDistanceKm: km
                        )
                    }
                )
                // 지도 도구(장소 검색·지도 종류)는 지도 우상단에 모아 둔다.
                HStack(spacing: 6) {
                    placeSearchField
                    MapStylePicker(
                        selection: mapStyle,
                        routeColor: routeColor,
                        routeColorOptions: RouteColorMode.options(hasSurface: surfaceStatus?.analysis != nil)
                    )
                }
                .padding(8)
            }
            .overlay(alignment: .topLeading) {
                if isCalculating {
                    Label("경로 계산 중…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .padding(6)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                }
            }
            .frame(minHeight: 200)
            elevationPane
                .frame(minHeight: 120)
                .overlay(alignment: .top) {
                    if let elevationFillStatus {
                        Label(elevationFillStatus.message, systemImage: elevationFillStatus.symbol)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(6)
                    }
                }
        }
    }

    // MARK: - 고도 그래프

    @ViewBuilder
    private var elevationPane: some View {
        let pts = draft.allCourseTrackPoints
        if pts.isEmpty {
            ContentUnavailableView {
                Label("고도 데이터 없음", systemImage: "chart.xyaxis.line")
            } description: {
                Text("경로를 추가하면 고도 그래프가 표시됩니다.")
            }
        } else {
            ElevationChartView(
                trackPoints: pts,
                markers: elevationMarkers(),
                focusedDistanceKm: focusedDistanceKm(),
                hoverInfo: $hoverInfo,
                rangeSelection: $rangeSelection,
                pinnedDistanceKm: $pinnedDistanceKm,
                selectedElevationRangeKm: draft.selectedSectionCourseRangeKm,
                zoomsToRangeSelection: true,
                zoomResetToken: zoomResetToken,
                onAddCueAtHover: { km in
                    addCueFromElevation(distanceKm: km, trackPoints: pts)
                },
                onSplitSectionAtHover: { km in
                    splitSectionFromElevation(distanceKm: km)
                },
                onSearchAtHover: { _ in
                    triggerSearch()
                },
                onBackgroundClick: { selectedCueID = nil },
                unpavedRangesKm: surfaceStatus?.analysis?.unpavedRuns.map { $0.startKm...$0.endKm } ?? []
            )
        }
    }

    /// 노면 소스가 있으면 코스 전체의 노면을 구한다. 편집하는 동안 잦게 바뀌므로 잠깐 기다렸다가 계산한다.
    /// OSRM 경로·직선 구간처럼 고도가 없는 leg에 DEM 고도를 채운다.
    /// 조회 한도에 걸리면 간격을 늘려 가며 다시 시도한다.
    private func fillMissingElevations() async {
        let legs = draft.legsMissingElevation
        guard !legs.isEmpty else {
            elevationFillStatus = nil
            return
        }
        // 점을 끌어 옮기는 동안 연달아 바뀌므로 잠깐 기다렸다가 조회한다.
        var retryDelays: [Duration] = [.milliseconds(300), .seconds(15), .seconds(30), .seconds(60)]
        while !retryDelays.isEmpty {
            try? await Task.sleep(for: retryDelays.removeFirst())
            guard !Task.isCancelled else { return }
            if elevationFillStatus != .failed { elevationFillStatus = .loading }
            let results = await ElevationService.shared.fillMissingElevations(legs.map(\.trackPoints))
            guard !Task.isCancelled else { return }
            var filled: [UUID: [TrackPointCodable]] = [:]
            for (leg, points) in zip(legs, results) {
                if let points { filled[leg.id] = points }
            }
            if filled.count == legs.count {
                elevationFillStatus = nil
                draft.applyFilledElevations(filled)
                return
            }
            elevationFillStatus = .failed
            // 일부라도 채우면 빠진 leg 목록이 바뀌어 이 task가 새로 시작된다.
            draft.applyFilledElevations(filled)
        }
        elevationFillStatus = .gaveUp
    }

    private func loadSurface() async {
        let store = MapFileStore.shared
        let points = draft.allCourseTrackPoints
        guard store.surfaceSource != nil, points.count >= 2 else {
            surfaceStatus = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        if surfaceStatus?.analysis == nil {
            surfaceStatus = .loading
        }
        let status = await store.surfaceStatus(for: points)
        guard !Task.isCancelled else { return }
        surfaceStatus = status
    }

    private func focusedDistanceKm() -> Double? {
        guard let id = selectedCueID,
              let cue = draft.cuePoints.first(where: { $0.id == id }) else { return nil }
        return draft.selectedSectionCourseStartKm + cue.distanceMeters / 1000
    }

    private func addCueFromElevation(distanceKm: Double, trackPoints pts: [TrackPoint]) {
        guard !pts.isEmpty else { return }
        var bestIdx = 0
        var bestDist = Double.infinity
        for (i, tp) in pts.enumerated() {
            let d = abs(tp.cumKm - distanceKm)
            if d < bestDist { bestDist = d; bestIdx = i }
        }
        let snap = pts[bestIdx]
        guard let sectionIndex = draft.sectionIndex(containingCourseDistanceKm: snap.cumKm) else {
            NSSound.beep()
            return
        }
        let sectionStartKm = draft.courseStartKm(forSectionAt: sectionIndex)

        let alert = NSAlert()
        alert.messageText = "큐시트 추가"
        alert.addButton(withTitle: "추가")
        alert.addButton(withTitle: "취소")

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
        stack.orientation = .vertical; stack.spacing = 8
        let nameField = NSTextField(frame: .zero)
        nameField.placeholderString = "이름"
        let typePopup = NSPopUpButton()
        for t in cuePointTypes { typePopup.addItem(withTitle: t.label) }
        typePopup.selectItem(withTitle: cuePointLabel(for: "Straight"))
        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(typePopup)
        alert.accessoryView = stack

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let selectedLabel = typePopup.titleOfSelectedItem ?? ""
        let selectedValue = cuePointTypes.first { $0.label == selectedLabel }?.value ?? "Straight"
        let cue = CourseCuePoint(
            lat: snap.lat, lon: snap.lon,
            name: nameField.stringValue,
            pointType: selectedValue,
            notes: "",
            distanceMeters: (snap.cumKm - sectionStartKm) * 1000
        )
        draft.selectSection(draft.sections[sectionIndex].id)
        draft.appendCuePoint(cue)
    }

    private func splitSectionFromElevation(distanceKm: Double) {
        guard let sectionIndex = draft.sectionIndex(containingCourseDistanceKm: distanceKm) else {
            NSSound.beep()
            return
        }
        let sectionStartKm = draft.courseStartKm(forSectionAt: sectionIndex)
        draft.selectSection(draft.sections[sectionIndex].id)
        guard draft.splitSelectedSection(atDistanceKm: distanceKm - sectionStartKm) else {
            NSSound.beep()
            return
        }
        pinnedDistanceKm = nil
    }

    private func saveDraftTCX() {
        let title = draft.normalizedTitle
        guard !title.isEmpty else {
            NSSound.beep()
            return
        }

        Exporter.saveTCX(filename: title) { options in
            return try? CourseTCXFileCoder.makeTCXData(
                title: title,
                tracks: draft.allCourseSectionTrackPoints,
                trackNames: draft.allCourseSectionNames,
                cuePoints: applyExportOptions(options, to: draft.allCourseCuePoints)
            )
        }
    }

    private func saveDraftGPX() {
        let title = draft.normalizedTitle
        guard !title.isEmpty else {
            NSSound.beep()
            return
        }

        Exporter.saveGPX(filename: title) {
            try? CourseGPXFileCoder.makeGPXData(
                title: title,
                tracks: draft.allCourseSectionTrackPoints,
                cuePoints: draft.allCourseCuePoints
            )
        }
    }

    private func applyExportOptions(_ options: TCXExportOptions, to cuePoints: [CourseCuePoint]) -> [CourseCuePoint] {
        guard options.useNameAsNotes else { return cuePoints }
        return cuePoints.map { cue in
            var copy = cue
            copy.notes = cue.name
            return copy
        }
    }

    private func elevationMarkers() -> [ElevationMarker] {
        draft.allCourseCuePoints.compactMap { cue in
            guard cue.lat != 0 || cue.lon != 0 else { return nil }
            return ElevationMarker(
                id: cue.id.uuidString,
                cumKm: cue.distanceMeters / 1000,
                label: cue.name.isEmpty ? cuePointLabel(for: cue.pointType) : cue.name,
                color: .cyan
            )
        }
    }

    // MARK: - 구간 추가 (드래그 → 시작/종료 큐시트)

    private func addSegmentFromRange(_ range: ChartRangeSelection) {
        guard let sectionIndex = sectionIndex(containing: range) else {
            NSSound.beep(); return
        }
        let sectionStartKm = draft.courseStartKm(forSectionAt: sectionIndex)
        let localRange = ChartRangeSelection(
            startKm: range.startKm - sectionStartKm,
            endKm: range.endKm - sectionStartKm,
            isDragging: range.isDragging
        )
        let pts = draft.sections[sectionIndex].trackPoints
        guard let stats = routeRangeStats(trackPoints: pts, range: localRange),
              let s = interpolateTrackPoint(in: pts, atDistanceKm: stats.startKm),
              let e = interpolateTrackPoint(in: pts, atDistanceKm: stats.endKm) else {
            NSSound.beep(); return
        }

        draft.selectSection(draft.sections[sectionIndex].id)

        let avgGrade = stats.averageGradePercent ?? 0
        let lengthKm = stats.lengthKm
        let gclass = Classification.gradeClass(value: avgGrade)
        let category = climbCategory(forAverageGrade: avgGrade, lengthKm: lengthKm)

        // 시작 PointType — 오르막일 때만 카테고리, 아니면 Sprint
        let startType = (gclass == .up)
            ? Classification.startPointType(category)
            : "Sprint"
        // 종료 PointType — 사양: 'Segment End' 라벨. 시각적으로는 정상/계곡 핀이 자연스럽다.
        let endType = (gclass == .down) ? "Valley" : "Summit"

        // 시작 이름 = "↗ 1.20km, 5.3% " (RouteWorkspaceView.makeCourseFromRoute 패턴과 동일)
        let distText = formatRouteDistance(lengthKm).replacingOccurrences(of: " ", with: "")
        let gradeText = String(format: "%.1f%%", avgGrade)
        let startName = "\(gclass.arrow)\(distText), \(gradeText) "

        let endName = "Segment End"

        var notesBits: [String] = ["Dist \(distText)", "Grade \(gradeText)"]
        if let cat = category { notesBits.append("Cat \(cat)") }
        notesBits.append("range-add")
        let baseNotes = notesBits.joined(separator: " | ")

        draft.appendCuePoint(CourseCuePoint(
            lat: s.lat, lon: s.lon,
            name: startName, pointType: startType,
            notes: baseNotes,
            distanceMeters: stats.startKm * 1000
        ))
        draft.appendCuePoint(CourseCuePoint(
            lat: e.lat, lon: e.lon,
            name: endName, pointType: endType,
            notes: baseNotes,
            distanceMeters: stats.endKm * 1000
        ))

        rangeSelection = nil
    }

    /// 평균 경사 + 길이 → Strava climb_category 근사 ("4"|"3"|"2"|"1"|"HC", 또는 nil → Sprint)
    /// score = length(m) * grade(%). 1.5% 이하/내리막은 nil.
    private func climbCategory(forAverageGrade grade: Double, lengthKm km: Double) -> String? {
        guard grade > Classification.gradeFlatThreshold, km > 0 else { return nil }
        let score = km * 1000 * grade
        if score >= 80_000 { return "HC" }
        if score >= 64_000 { return "1" }
        if score >= 32_000 { return "2" }
        if score >= 16_000 { return "3" }
        if score >= 8_000  { return "4" }
        return nil
    }

    // MARK: - 카카오 검색

    /// 툴바 엔터/버튼 → 현재 맵 visible rect로 즉시 검색
    private func triggerSearch() {
        searchResults = []
        searchError = nil
        if let map = mapViewRef {
            performSearch(in: map.visibleMapRect)
        }
    }

    private func performSearch(in rect: MKMapRect) {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        isSearching = true
        searchError = nil
        Task {
            do {
                let results = try await KakaoLocalSearch.search(query: query, in: rect)
                await MainActor.run {
                    searchResults = results
                    if results.isEmpty { searchError = "검색 결과 없음" }
                    isSearching = false
                }
            } catch {
                await MainActor.run {
                    searchError = error.localizedDescription
                    searchResults = []
                    isSearching = false
                }
            }
        }
    }

    // MARK: - 툴바

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem {
            // Undo / Redo — draft.undoCount를 읽어 canUndo/canRedo 변화 시 재렌더링
            let _ = draft.undoCount
            ControlGroup {
                Button {
                    draft.undoManager.undo()
                } label: {
                    Label("실행 취소", systemImage: "arrow.uturn.backward")
                }
                .disabled(!draft.undoManager.canUndo)
                .help(draft.undoManager.canUndo ? "실행 취소: \(draft.undoManager.undoActionName)" : "실행 취소")
                .keyboardShortcut("z", modifiers: .command)

                Button {
                    draft.undoManager.redo()
                } label: {
                    Label("다시 실행", systemImage: "arrow.uturn.forward")
                }
                .disabled(!draft.undoManager.canRedo)
                .help(draft.undoManager.canRedo ? "다시 실행: \(draft.undoManager.redoActionName)" : "다시 실행")
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }

        ToolbarItem {
            RouteProfilePicker(selection: routeProfile)
        }

        ToolbarSpacer(.flexible)

        ToolbarItem(placement: .primaryAction) {
            Button("취소") {
                if draft.hasChanges {
                    showDiscardConfirm = true
                } else {
                    closeEditor()
                }
            }
        }

        ToolbarItem(placement: .confirmationAction) {
            Button("저장") {
                draft.commit(to: course)
                if let onSave {
                    onSave()
                } else {
                    dismiss()
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!draft.hasValidTitle)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    /// 카카오 장소 검색 칸. 지도의 현재 화면 범위를 검색하므로 지도 위에 띄운다.
    private var placeSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("장소 검색 (화면 범위)", text: $searchQuery)
                .textFieldStyle(.plain)
                .frame(width: 170)
                .onSubmit { triggerSearch() }
            if isSearching {
                ProgressView().controlSize(.small)
            } else if !searchResults.isEmpty {
                Text("\(searchResults.count)건")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    searchQuery = ""
                    searchResults = []
                    searchError = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("검색 초기화")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.separator, lineWidth: 0.5)
        )
        .help(searchError ?? "카카오 로컬 검색")
    }

    private func closeEditor() {
        if let onCancel {
            onCancel()
        } else {
            dismiss()
            NSApp.keyWindow?.close()
        }
    }
}

private struct RouteProfilePicker: View {
    @Binding var selection: OSRMRouteProfile

    var body: some View {
        Picker("라우팅 프로필", selection: $selection) {
            ForEach(OSRMRouteProfile.allCases) { profile in
                Label(profile.label, systemImage: profile.symbol)
                    .tag(profile)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .help("경로 계산 프로필")
    }
}

// MARK: - CourseEditorCuesheetSidebar

/// 좌측 큐시트 사이드바. 거리 순으로 정렬하고, 상세 수정은 별도 시트에서 처리한다.
private struct CourseEditorCuesheetSidebar: View {
    var draft: CourseEditorDraft
    @Binding var selectedCueID: UUID?
    @Binding var pinnedDistanceKm: Double?
    var onEditCue: (UUID) -> Void

    @State private var showAddSheet = false
    @State private var newName = ""
    @State private var newType = "Straight"
    @State private var showDeleteSectionConfirm = false
    @State private var sectionImportCandidates: CourseSectionImportCandidates?
    @State private var renamingSectionID: UUID?
    @State private var renameText = ""
    @State private var colorPopoverSectionID: UUID?
    @FocusState private var isRenameFieldFocused: Bool

    /// distanceMeters 기준 정렬. 동일 거리에서는 추가 순서를 보존.
    private var sortedCues: [CourseCuePoint] {
        draft.cuePoints.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    var body: some View {
        let pts = draft.allTrackPoints
        let elevationProgress = RouteElevationProgress(trackPoints: pts)

        VStack(spacing: 0) {
            sectionList

            Divider()

            HStack {
                Text("큐시트")
                    .font(.subheadline.bold())
                Text("\(draft.cuePoints.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: { showAddSheet = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("큐시트 항목 추가")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if draft.cuePoints.isEmpty {
                ContentUnavailableView {
                    Label("큐시트 없음", systemImage: "list.bullet")
                } description: {
                    Text("경로 위를 우클릭하거나\n+ 버튼으로 추가하세요.")
                        .font(.caption)
                }
                // macOS에서는 내용 크기만 차지해 사이드바 전체가 세로 가운데로 내려가므로,
                // 남는 높이를 채워 섹션 목록이 큐시트가 있을 때처럼 위에 붙게 한다.
                .frame(maxHeight: .infinity)
            } else {
                List(selection: $selectedCueID) {
                    ForEach(sortedCues) { cue in
                        CourseEditorCuePointListRow(
                            cue: cue,
                            progress: cueElevationProgress(for: cue, trackPoints: pts, progress: elevationProgress),
                            onEdit: { onEditCue(cue.id) },
                            onDelete: { deleteCue(cue.id) }
                        )
                        .tag(cue.id)
                        .contextMenu {
                            Button {
                                onEditCue(cue.id)
                            } label: {
                                Label("수정", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                deleteCue(cue.id)
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { offsets in
                        // sortedCues 기준 offset → draft.cuePoints의 실제 idx 매핑
                        let ids = offsets.map { sortedCues[$0].id }
                        let realOffsets = IndexSet(ids.compactMap { id in
                            draft.cuePoints.firstIndex(where: { $0.id == id })
                        })
                        draft.removeCuePoints(at: realOffsets)
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            CuePointAddSheet(
                name: $newName,
                type: $newType,
                onAdd: {
                    let cue = CourseCuePoint(lat: 0, lon: 0, name: newName,
                                            pointType: newType, notes: "", distanceMeters: 0)
                    draft.appendCuePoint(cue)
                    showAddSheet = false
                    newName = ""; newType = "Straight"
                },
                onCancel: {
                    showAddSheet = false
                    newName = ""; newType = "Straight"
                }
            )
        }
        .sheet(item: $sectionImportCandidates) { candidates in
            CourseSectionImportPicker(
                candidates: candidates,
                onAdd: { sections in
                    insertImportedSections(sections)
                    sectionImportCandidates = nil
                },
                onCancel: { sectionImportCandidates = nil }
            )
        }
        .confirmationDialog(
            "선택한 섹션을 삭제하시겠습니까?",
            isPresented: $showDeleteSectionConfirm,
            titleVisibility: .visible
        ) {
            Button("섹션 삭제", role: .destructive) {
                draft.deleteSelectedSection()
                pinnedDistanceKm = nil
            }
            Button("취소", role: .cancel) {}
        } message: {
            let section = draft.sections[draft.selectedSectionIndex]
            Text("경로 \(formatRouteDistance(section.distanceKm))와 큐시트 \(section.cuePoints.count)개가 함께 삭제됩니다.")
        }
    }

    /// csb·tcx·gpx 파일을 골라 그 안의 섹션을 넣는다. 섹션이 하나면 바로 넣고, 여러 개면 고르게 한다.
    private func addSectionsFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = CourseSectionImporter.readableContentTypes
        panel.prompt = "추가"
        panel.message = "섹션을 가져올 CSB, TCX, GPX 파일을 선택하세요"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let sections = try CourseSectionImporter.sections(from: url)
            switch sections.count {
            case 0:
                showSectionImportError("이 파일에는 추가할 섹션이 없습니다.", detail: url.lastPathComponent)
            case 1:
                insertImportedSections(sections)
            default:
                sectionImportCandidates = CourseSectionImportCandidates(
                    fileName: url.lastPathComponent,
                    sections: sections
                )
            }
        } catch {
            showSectionImportError("파일에서 섹션을 불러올 수 없습니다.", detail: error.localizedDescription)
        }
    }

    private func insertImportedSections(_ sections: [CourseSection]) {
        draft.insertSections(sections)
        pinnedDistanceKm = nil
    }

    private func showSectionImportError(_ message: String, detail: String) {
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.runModal()
    }

    private var sectionList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("섹션")
                    .font(.subheadline.bold())
                Text("\(draft.sections.count)개")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button {
                        if let km = selectedPinnedLocalKm {
                            _ = draft.splitSelectedSection(atDistanceKm: km)
                        }
                    } label: {
                        Label("고정 지점에서 분할", systemImage: "scissors")
                    }
                    .disabled(selectedPinnedLocalKm == nil)

                    Button {
                        draft.mergeSelectedWithNext()
                        pinnedDistanceKm = nil
                    } label: {
                        Label("다음 섹션과 합치기", systemImage: "arrow.triangle.merge")
                    }
                    .disabled(!draft.canMergeSelectedWithNext)

                    Button {
                        draft.duplicateSection(draft.selectedSectionID)
                        pinnedDistanceKm = nil
                    } label: {
                        Label("섹션 복제", systemImage: "plus.square.on.square")
                    }

                    Divider()

                    Button(role: .destructive) {
                        showDeleteSectionConfirm = true
                    } label: {
                        Label("섹션 삭제", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Menu {
                    Button {
                        draft.addSection()
                    } label: {
                        Label("빈 섹션 추가", systemImage: "plus")
                    }
                    Button {
                        addSectionsFromFile()
                    } label: {
                        Label("파일에서 섹션 추가…", systemImage: "doc.badge.plus")
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("섹션 추가")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // 레이어 리스트: 아래에 있는 섹션일수록 맵에서 위에 그려지고, 순서는 곧 주행 순서다.
            List(selection: sectionSelection) {
                ForEach(Array(draft.sections.enumerated()), id: \.element.id) { index, section in
                    sectionRow(index: index, section: section)
                        .tag(section.id)
                        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 6))
                        .listRowSeparator(.hidden)
                        .contextMenu { sectionContextMenu(index: index, section: section) }
                }
                .onMove { source, destination in
                    draft.moveSections(fromOffsets: source, toOffset: destination)
                    pinnedDistanceKm = nil
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, Self.sectionRowHeight)
            .frame(height: min(CGFloat(draft.sections.count) * Self.sectionRowHeight + 10, 190))
            .padding(.bottom, 6)
        }
    }

    private static let sectionRowHeight: CGFloat = 28

    private var sectionSelection: Binding<UUID?> {
        Binding(
            get: { draft.selectedSectionID },
            set: { if let id = $0 { draft.selectSection(id) } }
        )
    }

    private func sectionRow(index: Int, section: CourseSection) -> some View {
        HStack(spacing: 6) {
            Button {
                draft.toggleSectionHidden(section.id)
                pinnedDistanceKm = nil
            } label: {
                Image(systemName: section.isHidden ? "eye.slash" : "eye")
                    .foregroundStyle(section.isHidden ? .tertiary : .secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(section.isHidden ? "섹션 보이기" : "섹션 가리기")

            Button {
                colorPopoverSectionID = section.id
            } label: {
                Circle()
                    .fill(Color(nsColor: SectionPalette.nsColor(section.colorHex)))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 0.5))
                    .frame(width: 18, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("섹션 색")
            .popover(
                isPresented: Binding(
                    get: { colorPopoverSectionID == section.id },
                    set: { if !$0, colorPopoverSectionID == section.id { colorPopoverSectionID = nil } }
                ),
                arrowEdge: .trailing
            ) {
                sectionColorPalette(for: section)
            }

            if renamingSectionID == section.id {
                TextField("섹션 \(index + 1)", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isRenameFieldFocused)
                    .onSubmit { commitSectionRename() }
                    .onExitCommand { renamingSectionID = nil }
                    .onChange(of: isRenameFieldFocused) { _, focused in
                        if !focused { commitSectionRename() }
                    }
            } else {
                Text(section.displayName(at: index))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .opacity(section.isHidden ? 0.45 : 1)
                    .onTapGesture(count: 2) { beginSectionRename(index: index, section: section) }
                    .help("더블클릭해서 이름 변경")
            }

            Spacer(minLength: 4)

            Text(formatRouteDistance(section.distanceKm))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .strikethrough(section.isHidden)
                .opacity(section.isHidden ? 0.6 : 1)
        }
        .frame(height: Self.sectionRowHeight)
    }

    private func sectionColorPalette(for section: CourseSection) -> some View {
        HStack(spacing: 8) {
            ForEach(SectionPalette.entries) { entry in
                let isCurrent = entry.hex.caseInsensitiveCompare(section.colorHex ?? "") == .orderedSame
                Button {
                    draft.setSectionColor(section.id, hex: entry.hex)
                    colorPopoverSectionID = nil
                } label: {
                    Circle()
                        .fill(Color(nsColor: SectionPalette.nsColor(entry.hex)))
                        .frame(width: 20, height: 20)
                        .overlay {
                            if isCurrent {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(entry.name)
                .accessibilityLabel(entry.name)
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func sectionContextMenu(index: Int, section: CourseSection) -> some View {
        Button {
            beginSectionRename(index: index, section: section)
        } label: {
            Label("이름 변경", systemImage: "pencil")
        }

        Button {
            draft.toggleSectionHidden(section.id)
            pinnedDistanceKm = nil
        } label: {
            Label(section.isHidden ? "보이기" : "가리기",
                  systemImage: section.isHidden ? "eye" : "eye.slash")
        }

        Menu {
            ForEach(SectionPalette.entries) { entry in
                Button(entry.name) { draft.setSectionColor(section.id, hex: entry.hex) }
            }
        } label: {
            Label("색", systemImage: "paintpalette")
        }

        Button {
            draft.duplicateSection(section.id)
            pinnedDistanceKm = nil
        } label: {
            Label("복제", systemImage: "plus.square.on.square")
        }

        Divider()

        Button {
            draft.selectSection(section.id)
            if let courseKm = pinnedDistanceKm,
               let km = draft.selectedSectionLocalDistanceKm(forCourseDistanceKm: courseKm) {
                _ = draft.splitSelectedSection(atDistanceKm: km)
            }
        } label: {
            Label("고정 지점에서 분할", systemImage: "scissors")
        }
        .disabled(draft.selectedSectionID != section.id || selectedPinnedLocalKm == nil)

        Button {
            draft.selectSection(section.id)
            draft.mergeSelectedWithNext()
            pinnedDistanceKm = nil
        } label: {
            Label("다음 섹션과 합치기", systemImage: "arrow.triangle.merge")
        }
        .disabled(index + 1 >= draft.sections.count)

        Button(role: .destructive) {
            draft.selectSection(section.id)
            showDeleteSectionConfirm = true
        } label: {
            Label("삭제", systemImage: "trash")
        }
    }

    private func beginSectionRename(index: Int, section: CourseSection) {
        draft.selectSection(section.id)
        renameText = section.name
        renamingSectionID = section.id
        isRenameFieldFocused = true
    }

    private func commitSectionRename() {
        guard let id = renamingSectionID else { return }
        renamingSectionID = nil
        draft.renameSection(id, to: renameText)
    }

    private var selectedPinnedLocalKm: Double? {
        pinnedDistanceKm.flatMap {
            draft.selectedSectionLocalDistanceKm(forCourseDistanceKm: $0)
        }
    }

    private func deleteCue(_ id: UUID) {
        guard let idx = draft.cuePoints.firstIndex(where: { $0.id == id }) else { return }
        draft.removeCuePoints(at: IndexSet(integer: idx))
    }

    private func cueElevationProgress(
        for cue: CourseCuePoint,
        trackPoints pts: [TrackPoint],
        progress: RouteElevationProgress
    ) -> RouteElevationProgressStats? {
        progress.stats(at: cueTrackIndex(cue, in: pts))
    }
}

// MARK: - CourseEditorCuePointListRow

private struct CourseEditorCuePointListRow: View {
    var cue: CourseCuePoint
    var progress: RouteElevationProgressStats?
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cue.name.isEmpty ? cuePointLabel(for: cue.pointType) : cue.name)
                    .font(.body)
                    .lineLimit(1)
                Text(cuePointLabel(for: cue.pointType))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                if let progress {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.up.right")
                        Text(formatAccumulatedElevation(progress.ascentFromStart))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                if cue.distanceMeters > 0 {
                    Text(String(format: "%.1f km", cue.distanceMeters / 1000))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Menu {
                Button(action: onEdit) {
                    Label("수정", systemImage: "pencil")
                }
                Divider()
                Button(role: .destructive, action: onDelete) {
                    Label("삭제", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24, height: 24)
            .help("큐시트 항목 메뉴")
        }
        .padding(.vertical, 2)
    }

    private func formatAccumulatedElevation(_ meters: Double) -> String {
        String(format: "%.0f m", meters)
    }
}

// MARK: - CuePointAddSheet

private struct CuePointAddSheet: View {
    @Binding var name: String
    @Binding var type: String
    var onAdd: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("큐시트 추가").font(.headline)
            TextField("이름", text: $name)
                .textFieldStyle(.roundedBorder)
            Picker("타입", selection: $type) {
                ForEach(cuePointTypes, id: \.value) { Text($0.label).tag($0.value) }
            }
            HStack {
                Button("취소", action: onCancel)
                Spacer()
                Button("추가", action: onAdd)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
    }
}

// MARK: - CuePointEditSheet

private struct CuePointEditSheet: View {
    var cue: CourseCuePoint
    var trackPoints: [TrackPoint]
    var onSave: (CourseCuePoint) -> Void
    var onCancel: () -> Void

    @State private var name: String
    @State private var pointType: String
    @State private var notes: String
    @State private var distanceKm: Double

    private var maximumDistanceKm: Double? {
        guard let total = trackPoints.last?.cumKm, total > 0 else { return nil }
        return total
    }

    init(
        cue: CourseCuePoint,
        trackPoints: [TrackPoint],
        onSave: @escaping (CourseCuePoint) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.cue = cue
        self.trackPoints = trackPoints
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: cue.name)
        _pointType = State(initialValue: cue.pointType)
        _notes = State(initialValue: cue.notes)
        let initialDistanceKm: Double = {
            guard let idx = cueTrackIndex(cue, in: trackPoints) else {
                return cue.distanceMeters / 1000
            }
            return trackPoints[idx].cumKm
        }()
        _distanceKm = State(initialValue: initialDistanceKm)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("큐시트 항목 수정")
                .font(.headline)

            Form {
                Section {
                    TextField("제목", text: $name)
                    Picker("타입", selection: $pointType) {
                        ForEach(cuePointPickerTypes(for: pointType), id: \.value) { type in
                            Text(type.label).tag(type.value)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text("메모")
                            .foregroundStyle(.secondary)
                        TextEditor(text: $notes)
                            .font(.body)
                            .frame(minHeight: 84)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .strokeBorder(.separator, lineWidth: 0.5)
                            )
                    }
                }

                Section {
                    HStack {
                        TextField(
                            "시작지점으로부터 거리",
                            value: $distanceKm,
                            format: .number.precision(.fractionLength(3))
                        )
                        Text("km")
                            .foregroundStyle(.secondary)
                    }
                    if let maximumDistanceKm {
                        Slider(
                            value: Binding(
                                get: { min(max(distanceKm, 0), maximumDistanceKm) },
                                set: { distanceKm = $0 }
                            ),
                            in: 0...maximumDistanceKm
                        )
                        HStack {
                            Text("0 m")
                            Spacer()
                            Text(formatRouteDistance(maximumDistanceKm))
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("위치")
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("취소", action: onCancel)
                Spacer()
                Button("저장") {
                    onSave(makeUpdatedCue())
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 430)
        .frame(minHeight: 460)
    }

    private func makeUpdatedCue() -> CourseCuePoint {
        let clampedKm = clampedDistanceKm()
        var updated = cue
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.pointType = pointType
        updated.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.distanceMeters = clampedKm * 1000

        if let point = interpolateTrackPoint(in: trackPoints, atDistanceKm: clampedKm) {
            updated.lat = point.lat
            updated.lon = point.lon
        }
        return updated
    }

    private func clampedDistanceKm() -> Double {
        let km = distanceKm.isFinite ? distanceKm : cue.distanceMeters / 1000
        guard let maximumDistanceKm else { return max(0, km) }
        return min(max(0, km), maximumDistanceKm)
    }
}

// MARK: - CourseEditorCueInspectorView

/// 우측 인스펙터: 선택된 큐 상세 정보. 보기 화면 CourseCueInspectorView와 동일 정보 +
/// "수정", "삭제" 버튼.
private struct CourseEditorCueInspectorView: View {
    var course: CourseRecord
    var draft: CourseEditorDraft
    var selectedCueID: UUID?
    var onEditCue: (UUID) -> Void

    private var sortedCues: [CourseCuePoint] {
        draft.cuePoints.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    private var trackPoints: [TrackPoint] { draft.allTrackPoints }

    @State private var isEditingTitle = false
    @State private var titleText = ""
    @FocusState private var isTitleFieldFocused: Bool

    private var titleHeader: some View {
        HStack(spacing: 6) {
            if isEditingTitle {
                TextField("코스 제목", text: $titleText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isTitleFieldFocused)
                    .onSubmit { commitTitleEdit() }
                    .onExitCommand { isEditingTitle = false }
                    .onChange(of: isTitleFieldFocused) { _, focused in
                        if !focused { commitTitleEdit() }
                    }
            } else {
                if !draft.hasValidTitle {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(draft.hasValidTitle ? draft.title : "제목 없음")
                    .font(.headline)
                    .foregroundStyle(draft.hasValidTitle ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(draft.hasValidTitle ? draft.title : "코스 제목을 입력하세요")
                Spacer()
                Button {
                    beginTitleEdit()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("제목 수정")
                .accessibilityLabel("제목 수정")
            }
        }
    }

    private func beginTitleEdit() {
        titleText = draft.title
        isEditingTitle = true
        isTitleFieldFocused = true
    }

    /// 빈 제목은 반영하지 않고 기존 제목을 유지한다.
    private func commitTitleEdit() {
        guard isEditingTitle else { return }
        isEditingTitle = false
        let trimmed = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft.updateTitle(trimmed)
    }

    var body: some View {
        VStack(spacing: 0) {
            titleHeader
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            Divider()

            if let cueID = selectedCueID,
               let cue = draft.cuePoints.first(where: { $0.id == cueID }) {
                ScrollView {
                    cueDetail(cue: cue)
                        .padding(16)
                }
            } else {
                ScrollView {
                    courseOverview()
                        .padding(16)
                }
            }
        }
    }

    @ViewBuilder
    private func courseOverview() -> some View {
        let pts = trackPoints
        let cues = sortedCues
        let totalKm = pts.last?.cumKm ?? 0
        let elevation = courseElevationStats(pts)
        let activeSection = draft.sections[draft.selectedSectionIndex]

        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("코스 개요")
                    .font(.title3.weight(.semibold))
                Text("큐시트를 선택하지 않은 상태입니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            section(title: "기본 정보", icon: "doc.text") {
                infoRow("생성일", value: formatDate(course.createdAt))
                infoRow("파일 경로", value: displayText(course.sourceFilePath))
                infoRow("출처 Route ID", value: displayText(course.sourceRouteID))
            }

            section(title: "주행 요약", icon: "speedometer") {
                infoRow("총 거리", value: formatKm(totalKm))
                infoRow("획득고도", value: formatEle(activeSection.elevationGainM), valueColor: .red)
                infoRow("누적 하강", value: formatEle(activeSection.elevationLossM), valueColor: .blue)
                infoRow("상승 밀도", value: formatElevationDensity(activeSection.elevationGainM, totalKm: totalKm))
            }

            section(title: "고도 범위", icon: "mountain.2") {
                infoRow("시작 고도", value: formatEle(pts.first?.ele))
                infoRow("종료 고도", value: formatEle(pts.last?.ele))
                infoRow("최저 고도", value: formatEle(elevation.min))
                infoRow("최고 고도", value: formatEle(elevation.max))
                infoRow("최고-최저", value: formatEle(elevation.span))
            }

            section(title: "경로 구성", icon: "point.3.connected.trianglepath.dotted") {
                infoRow("전체 섹션", value: formatCount(draft.sections.count))
                infoRow("활성 섹션 경유지", value: formatCount(draft.routePoints.count))
                infoRow("활성 섹션 트랙 구간", value: formatCount(draft.trackSegments.count))
                infoRow("트랙 포인트", value: formatCount(pts.count))
                infoRow("고도 데이터", value: elevation.hasData ? "있음" : "없음")
            }

            section(title: "큐시트 요약", icon: "list.bullet.rectangle") {
                infoRow("전체 큐", value: formatCount(cues.count))
                infoRow("타입 구성", value: cueTypeSummary(cues))
                if let first = cues.first {
                    infoRow("첫 큐", value: cueSummary(first, trackPoints: pts))
                }
                if let last = cues.last {
                    infoRow("마지막 큐", value: cueSummary(last, trackPoints: pts))
                }
            }
        }
    }

    @ViewBuilder
    private func cueDetail(cue: CourseCuePoint) -> some View {
        let pts = trackPoints
        let totalKm = pts.last?.cumKm ?? 0
        let cueIdx = cueTrackIndex(cue, in: pts)
        let cueKm = cueIdx.map { pts[$0].cumKm } ?? (cue.distanceMeters / 1000)
        let cueEle = cueIdx.flatMap { pts[$0].ele }
        let elevationProgress = RouteElevationProgress(trackPoints: pts).stats(at: cueIdx)

        let cues = sortedCues
        let pos = cues.firstIndex(where: { $0.id == cue.id })
        let prev = (pos.flatMap { $0 > 0 ? cues[$0 - 1] : nil })
        let next = (pos.flatMap { $0 + 1 < cues.count ? cues[$0 + 1] : nil })

        VStack(alignment: .leading, spacing: 20) {
            // 헤더 (이름 + 타입 + 수정/삭제)
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(cue.name.isEmpty ? cuePointLabel(for: cue.pointType) : cue.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(cuePointLabel(for: cue.pointType))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        onEditCue(cue.id)
                    } label: {
                        Label("수정", systemImage: "pencil")
                    }
                    .controlSize(.small)

                    Button(role: .destructive) {
                        if let idx = draft.cuePoints.firstIndex(where: { $0.id == cue.id }) {
                            draft.removeCuePoints(at: IndexSet(integer: idx))
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .help("이 큐 삭제")
                }
            }

            section(title: "위치", icon: "location") {
                infoRow("시작점으로부터", value: formatKm(cueKm))
                infoRow("종료점까지", value: formatKm(max(0, totalKm - cueKm)))
                infoRow("고도", value: formatEle(cueEle))
            }

            section(title: "누적 고도", icon: "mountain.2") {
                infoRow("시작점부터 누적 상승", value: formatEle(elevationProgress?.ascentFromStart), valueColor: .red)
                infoRow("시작점부터 누적 하강", value: formatEle(elevationProgress?.descentFromStart), valueColor: .blue)
                infoRow("종료점까지 남은 상승", value: formatEle(elevationProgress?.ascentToEnd), valueColor: .red)
                infoRow("종료점까지 남은 하강", value: formatEle(elevationProgress?.descentToEnd), valueColor: .blue)
            }

            section(title: "이전 큐", icon: "arrow.up.to.line") {
                if let prev {
                    let prevName = prev.name.isEmpty ? cuePointLabel(for: prev.pointType) : prev.name
                    infoRow("이름", value: prevName, valueColor: .primary)
                    infoRow("거리 차이", value: formatKm(max(0, (cue.distanceMeters - prev.distanceMeters) / 1000)))
                    infoRow("고도 차이", value: formatEleDelta(from: prev, to: cue, pts: pts))
                } else {
                    Text("이전 큐가 없습니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
            }

            section(title: "다음 큐", icon: "arrow.down.to.line") {
                if let next {
                    let nextName = next.name.isEmpty ? cuePointLabel(for: next.pointType) : next.name
                    infoRow("이름", value: nextName, valueColor: .primary)
                    infoRow("거리 차이", value: formatKm(max(0, (next.distanceMeters - cue.distanceMeters) / 1000)))
                    infoRow("고도 차이", value: formatEleDelta(from: cue, to: next, pts: pts))
                } else {
                    Text("다음 큐가 없습니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
            }

            if !cue.notes.isEmpty {
                section(title: "메모", icon: "note.text") {
                    Text(cue.notes)
                        .font(.callout)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                }
            }
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

    private func formatCount(_ count: Int) -> String {
        "\(count)개"
    }

    private func formatDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().hour().minute())
    }

    private func formatElevationDensity(_ ascent: Double?, totalKm: Double) -> String {
        guard let ascent, totalKm > 0 else { return "—" }
        return String(format: "%.0f m/km", ascent / totalKm)
    }

    private func displayText(_ value: String?) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "—" : trimmed
    }

    private func cueSummary(_ cue: CourseCuePoint, trackPoints pts: [TrackPoint]) -> String {
        let km = cueDistanceKm(cue, trackPoints: pts)
        return "\(formatKm(km)) · \(cueDisplayName(cue))"
    }

    private func cueDisplayName(_ cue: CourseCuePoint) -> String {
        cue.name.isEmpty ? cuePointLabel(for: cue.pointType) : cue.name
    }

    private func cueDistanceKm(_ cue: CourseCuePoint, trackPoints pts: [TrackPoint]) -> Double {
        if let idx = cueTrackIndex(cue, in: pts) {
            return pts[idx].cumKm
        }
        return cue.distanceMeters / 1000
    }

    private func cueTypeSummary(_ cues: [CourseCuePoint]) -> String {
        guard !cues.isEmpty else { return "—" }
        let counts = Dictionary(grouping: cues, by: { cuePointLabel(for: $0.pointType) })
            .mapValues(\.count)
        let sorted = counts.sorted {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }
        let visible = sorted.prefix(3).map { "\($0.key) \($0.value)" }
        let hiddenCount = max(0, sorted.count - visible.count)
        if hiddenCount > 0 {
            return (visible + ["외 \(hiddenCount)종"]).joined(separator: ", ")
        }
        return visible.joined(separator: ", ")
    }

    private func courseElevationStats(_ pts: [TrackPoint]) -> (
        min: Double?,
        max: Double?,
        span: Double?,
        ascent: Double?,
        descent: Double?,
        hasData: Bool
    ) {
        let elevations = pts.compactMap(\.ele)
        let minEle = elevations.min()
        let maxEle = elevations.max()
        let span = minEle.flatMap { lo in maxEle.map { max(0, $0 - lo) } }

        var ascent: Double = 0
        var descent: Double = 0
        var hasPair = false
        guard pts.count > 1 else {
            return (minEle, maxEle, span, nil, nil, !elevations.isEmpty)
        }

        for i in 1..<pts.count {
            guard let prevEle = pts[i - 1].ele, let currEle = pts[i].ele else { continue }
            hasPair = true
            let diff = currEle - prevEle
            if diff > 0 {
                ascent += diff
            } else {
                descent += -diff
            }
        }

        return (minEle, maxEle, span, hasPair ? ascent : nil, hasPair ? descent : nil, !elevations.isEmpty)
    }

    private func formatEleDelta(from a: CourseCuePoint, to b: CourseCuePoint, pts: [TrackPoint]) -> String {
        guard let aIdx = cueTrackIndex(a, in: pts),
              let bIdx = cueTrackIndex(b, in: pts),
              let aEle = pts[aIdx].ele, let bEle = pts[bIdx].ele else { return "—" }
        let diff = bEle - aEle
        let sign = diff > 0 ? "+" : (diff < 0 ? "" : "")
        return String(format: "%@%.0f m", sign, diff)
    }
}

// MARK: - CourseEditMapView

struct CourseEditMapView: NSViewRepresentable {
    var draft: CourseEditorDraft
    @Binding var isCalculating: Bool
    @Binding var searchResults: [KakaoLocalResult]
    @Binding var mapViewRef: MKMapView?
    var selectedCueID: UUID?
    var rangeSelection: ChartRangeSelection?
    /// 코스 전체 기준(km) 선택 구간. 확정되면 해당 구간으로 카메라를 확대 이동한다.
    /// `rangeSelection`은 활성 섹션 안의 구간만 그리므로 카메라 이동은 별도로 받는다.
    var cameraRangeSelection: ChartRangeSelection? = nil
    /// 값이 바뀔 때마다 카메라를 코스 전체 보기로 되돌린다.
    var zoomResetToken: Int = 0
    /// 고도 그래프와 지도가 함께 쓰는 hover 지점. 거리는 코스 전체 기준(km)이다.
    @Binding var hoverInfo: RouteHoverInfo?
    /// 고정 지점의 코스 누적 거리(km). 선택한 섹션이 아닌 섹션의 지점일 수도 있다.
    var pinnedDistanceKm: Double?
    var mapStyle: MapStyleOption = .standard
    /// 기본 지도 위에 덮을 사용자 지도 파일.
    var tileSource: GarminTileSource? = nil
    /// 코스 선을 칠하는 방식.
    var routeColorMode: RouteColorMode = .section
    /// 노면 방식일 때 흰 점선을 그을 비포장 구간. 인덱스는 `draft.allCourseTrackPoints` 기준이다.
    var unpavedRuns: [CourseSurfaceAnalysis.Run]? = nil
    var routingProfile: OSRMRouteProfile = .defaultProfile
    var onSelectCue: (UUID) -> Void
    var onDeselectFocus: () -> Void
    var onSearchInVisibleRect: (MKMapRect) -> Void
    var onPinDistance: ((Double) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(draft: draft, isCalculatingBinding: $isCalculating,
                    searchResultsBinding: $searchResults,
                    routingProfile: routingProfile,
                    onSelectCue: onSelectCue,
                    onDeselectFocus: onDeselectFocus,
                    onPinDistance: onPinDistance,
                    onSearchInVisibleRect: onSearchInVisibleRect)
    }

    static func dismantleNSView(_ map: MKMapView, coordinator: Coordinator) {
        if let hover = map as? HoverMapView {
            hover.onRouteMouseMoved = nil
            hover.onRouteMouseExited = nil
        }
        coordinator.hoverInfoBinding = nil
        coordinator.removeTooltip()
    }

    func makeNSView(context: Context) -> MKMapView {
        let map = HoverMapView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        let coordinator = context.coordinator
        map.onRouteMouseMoved = { [weak coordinator] map, point in
            coordinator?.handleMouseMoved(in: map, point: point)
        }
        map.onRouteMouseExited = { [weak coordinator] map in
            coordinator?.clearHover(in: map)
        }
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        let style = AppliedMapStyle(style: mapStyle, flat: tileSource != nil)
        applyMapStyle(mapStyle, to: map, flat: style.flat)
        context.coordinator.appliedMapStyle = style
        context.coordinator.mapView = map
        DispatchQueue.main.async { mapViewRef = map }

        let rightClick = NSClickGestureRecognizer(target: context.coordinator,
                                                   action: #selector(Coordinator.handleRightClick(_:)))
        rightClick.buttonMask = 2
        map.addGestureRecognizer(rightClick)

        let leftClick = NSClickGestureRecognizer(target: context.coordinator,
                                                  action: #selector(Coordinator.handleLeftClick(_:)))
        leftClick.buttonMask = 1
        map.addGestureRecognizer(leftClick)

        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let style = AppliedMapStyle(style: mapStyle, flat: tileSource != nil)
        if context.coordinator.appliedMapStyle != style {
            applyMapStyle(mapStyle, to: map, flat: style.flat)
            context.coordinator.appliedMapStyle = style
        }
        map.syncMapFileOverlay(tileSource)
        context.coordinator.draft = draft
        context.coordinator.hoverInfoBinding = $hoverInfo
        context.coordinator.onSelectCue = onSelectCue
        context.coordinator.onDeselectFocus = onDeselectFocus
        context.coordinator.onPinDistance = onPinDistance
        context.coordinator.onSearchInVisibleRect = onSearchInVisibleRect
        context.coordinator.routingProfile = routingProfile
        context.coordinator.routeColorMode = routeColorMode
        context.coordinator.refresh()
        context.coordinator.syncUnpaved(in: map, runs: unpavedRuns)
        context.coordinator.updateSearchAnnotations(map: map, results: searchResults)
        context.coordinator.syncFocusedCue(in: map, focusedID: selectedCueID)
        context.coordinator.syncRangeSelection(in: map, selection: rangeSelection)
        context.coordinator.syncCameraRange(in: map, selection: cameraRangeSelection)
        context.coordinator.syncZoomReset(in: map, token: zoomResetToken)
        context.coordinator.syncHoverLocation(in: map, info: hoverInfo)
        context.coordinator.syncPinnedLocation(in: map, distanceKm: pinnedDistanceKm)
        promoteRangeEndpointAnnotationViews(in: map)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var draft: CourseEditorDraft
        var isCalculatingBinding: Binding<Bool>
        var searchResultsBinding: Binding<[KakaoLocalResult]>
        var onSelectCue: (UUID) -> Void
        var onDeselectFocus: () -> Void
        var onPinDistance: ((Double) -> Void)?
        var onSearchInVisibleRect: (MKMapRect) -> Void
        var routingProfile: OSRMRouteProfile
        var appliedMapStyle: AppliedMapStyle?
        var routeColorMode: RouteColorMode = .section
        weak var mapView: MKMapView?
        private var unpavedOverlay: CourseUnpavedMultiPolyline?
        private var appliedUnpavedRuns: [CourseSurfaceAnalysis.Run]?

        /// 코스 선 두께. 노면 방식은 흰 점선이 들어가도록 더 굵게 긋는다.
        private var routeLineWidth: CGFloat { max(4, routeColorMode.lineWidth) }

        private var draggingIndex: Int?
        private var needsFitOnFirstLoad = true
        private var builtRouteSignature: String = ""
        private var builtSearchSignature: String = ""
        private var lastFocusedCueID: UUID?
        private var rangePolyline: RangeSelectionPolyline?
        private var rangeEndpointAnnotations: [RangeEndpointAnnotation] = []
        private var lastRangeSignature: String = ""
        private var lastCameraRangeSignature: String = ""
        private var appliedZoomResetToken = 0
        private var hoverAnnotation: HoverAnnotation?
        var hoverInfoBinding: Binding<RouteHoverInfo?>?
        private let tooltip = RouteHoverTooltip()
        /// 지도 위 마우스로 hover 중이면 true. 이때는 말풍선을 마우스 옆에 둔다.
        private var mapMouseHoverActive = false
        /// 보이는 모든 섹션을 이은 코스 트랙(km는 코스 전체 기준)과 섹션 경계 인덱스.
        /// 마우스가 움직일 때마다 다시 만들지 않도록 경로가 바뀔 때만 갱신한다.
        private var courseTrackPoints: [TrackPoint] = []
        private var courseSectionBreaks: Set<Int> = []
        private var pinnedAnnotation: PinnedLocationAnnotation?
        private var lastPinnedSignature: String = ""
        /// refresh()로 annotation만 다시 그릴 때(같은 거리)는 카메라를 움직이지 않도록 별도로 기억한다.
        private var lastRevealedPinnedKm: Double?

        init(draft: CourseEditorDraft, isCalculatingBinding: Binding<Bool>,
             searchResultsBinding: Binding<[KakaoLocalResult]>,
             routingProfile: OSRMRouteProfile,
             onSelectCue: @escaping (UUID) -> Void,
             onDeselectFocus: @escaping () -> Void,
             onPinDistance: ((Double) -> Void)?,
             onSearchInVisibleRect: @escaping (MKMapRect) -> Void) {
            self.draft = draft
            self.isCalculatingBinding = isCalculatingBinding
            self.searchResultsBinding = searchResultsBinding
            self.routingProfile = routingProfile
            self.onSelectCue = onSelectCue
            self.onDeselectFocus = onDeselectFocus
            self.onPinDistance = onPinDistance
            self.onSearchInVisibleRect = onSearchInVisibleRect
        }

        // MARK: 맵 갱신

        func refresh() {
            guard let map = mapView else { return }
            // 모든 섹션 형상과 활성 섹션을 포함한다.
            let routeSig = draft.sections.map { section in
                let legs = section.legs.map { leg in
                    let first = leg.trackPoints.first
                    let last = leg.trackPoints.last
                    // 경사도 색은 고도에 따라 달라지므로 고도 채우기 뒤에도 다시 그리게 한다.
                    let hasEle = first?.ele != nil && last?.ele != nil
                    return "\(leg.kind.rawValue):\(leg.trackPoints.count):\(first?.lat ?? 0),\(first?.lon ?? 0):\(last?.lat ?? 0),\(last?.lon ?? 0):\(hasEle)"
                }.joined(separator: ",")
                return "\(section.id):\(section.colorHex ?? ""):\(section.isHidden):\(legs)"
            }.joined(separator: "|") + "#active=\(draft.selectedSectionID)" + "#color=\(routeColorMode.rawValue)"
            let cueSig = draft.cuePoints.map { "\($0.id):\($0.lat),\($0.lon),\($0.pointType),\($0.name)" }.joined(separator: "|")
            let sig = routeSig + "##" + cueSig
            guard sig != builtRouteSignature else { return }
            builtRouteSignature = sig
            rebuildCourseTrack()

            // 사용자 지도 파일 오버레이는 경로와 상관없으므로 남겨 둔다.
            map.removeOverlays(map.routeOverlays)
            unpavedOverlay = nil
            appliedUnpavedRuns = nil
            let routeAnns = map.annotations.compactMap { $0 as? RoutePointAnnotation }
            let cueAnns = map.annotations.compactMap { $0 as? CuePointAnnotation }
            map.removeAnnotations(routeAnns + cueAnns)

            // RoutePoint 핸들은 활성 섹션에만 표시한다. 가린 섹션은 핸들·큐도 그리지 않는다.
            let showsActiveSection = !draft.isSelectedSectionHidden
            if showsActiveSection {
                for (i, rp) in draft.routePoints.enumerated() {
                    map.addAnnotation(RoutePointAnnotation(routePoint: rp, index: i))
                }
            }
            // z-index는 레이어 순서의 오름차순이다. 나중에 추가한 오버레이가 위에 그려지므로
            // 리스트 순서대로 추가하면 아래쪽(뒤) 섹션이 맵에서 위에 온다.
            for section in draft.sections where !section.isHidden {
                let color: NSColor
                switch routeColorMode {
                case .surface: color = RouteColorMode.surfaceColor
                case .solid: color = RouteColorMode.solidColor
                case .section, .grade: color = SectionPalette.nsColor(section.colorHex)
                }
                for leg in section.legs {
                    guard leg.trackPoints.count >= 2 else { continue }
                    let coords = leg.trackPoints.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                    }
                    if routeColorMode == .grade {
                        // 구간(leg)마다 경사도 구간을 나눠 그 경사 색으로 긋는다. 직선 구간의 점선은 그대로다.
                        let points = leg.trackPoints.map {
                            TrackPoint(lat: $0.lat, lon: $0.lon, ele: $0.ele, time: $0.time, cumKm: $0.cumKm)
                        }
                        for run in RouteGradeColoring.runs(for: points) {
                            let runCoords = Array(coords[run.startIndex...run.endIndex])
                            let polyline = SegmentPolyline(coordinates: runCoords, count: runCoords.count)
                            polyline.kind = leg.kind
                            polyline.color = run.band.color
                            map.addOverlay(polyline, level: .aboveRoads)
                        }
                        continue
                    }
                    let polyline = SegmentPolyline(coordinates: coords, count: coords.count)
                    polyline.kind = leg.kind
                    polyline.color = color
                    map.addOverlay(polyline, level: .aboveRoads)
                }
            }
            if showsActiveSection {
                for cue in draft.cuePoints where cue.lat != 0 || cue.lon != 0 {
                    map.addAnnotation(CuePointAnnotation(cue: cue))
                }
            }

            // refresh로 cue annotation을 새로 만들었으니, 선택 동기화 트리거
            lastFocusedCueID = nil
            // range overlay는 syncRangeSelection이 별도로 다시 만든다.
            lastRangeSignature = ""
            // hover·고정 지점은 다음 sync에서 새 경로 기준으로 다시 놓는다.
            if let hoverAnnotation { map.removeAnnotation(hoverAnnotation) }
            hoverAnnotation = nil
            if let pinnedAnnotation { map.removeAnnotation(pinnedAnnotation) }
            pinnedAnnotation = nil
            lastPinnedSignature = ""

            if needsFitOnFirstLoad && draft.sections.contains(where: { !$0.isHidden && !$0.routePoints.isEmpty }) {
                needsFitOnFirstLoad = false
                fitMap(map: map)
            }
        }

        // MARK: 검색 결과 어노테이션

        /// 비포장 구간의 흰 점선을 코스 선 위에 긋는다. 노면 방식이 아니면(runs가 nil) 걷어 낸다.
        /// 섹션이 바뀌는 곳에서는 점선을 끊는다.
        func syncUnpaved(in map: MKMapView, runs: [CourseSurfaceAnalysis.Run]?) {
            guard runs != appliedUnpavedRuns else { return }
            appliedUnpavedRuns = runs
            if let unpavedOverlay {
                map.removeOverlay(unpavedOverlay)
                self.unpavedOverlay = nil
            }
            guard let runs, !runs.isEmpty else { return }
            var breaks = Set<Int>()
            var end = -1
            for points in draft.allCourseSectionTrackPoints {
                end += points.count
                breaks.insert(end)
            }
            guard let overlay = CourseUnpavedMultiPolyline.make(
                runs: runs,
                trackPoints: draft.allCourseTrackPoints,
                breakAfter: breaks
            ) else { return }
            // 코스 선보다 위, 구간 선택 선보다 아래에 둔다.
            if let range = rangePolyline {
                map.insertOverlay(overlay, below: range)
            } else {
                map.addOverlay(overlay, level: .aboveRoads)
            }
            unpavedOverlay = overlay
        }

        func updateSearchAnnotations(map: MKMapView, results: [KakaoLocalResult]) {
            let sig = results.map(\.id).joined(separator: ",")
            guard sig != builtSearchSignature else { return }
            builtSearchSignature = sig

            let existing = map.annotations.compactMap { $0 as? SearchResultAnnotation }
            map.removeAnnotations(existing)
            for r in results {
                map.addAnnotation(SearchResultAnnotation(result: r))
            }
        }

        // MARK: 큐 포커스 동기화

        func syncFocusedCue(in map: MKMapView, focusedID: UUID?) {
            let cueAnns = map.annotations.compactMap { $0 as? CuePointAnnotation }
            guard let id = focusedID,
                  let annotation = cueAnns.first(where: { $0.cue.id == id }) else {
                if let selected = map.selectedAnnotations.first as? CuePointAnnotation {
                    map.deselectAnnotation(selected, animated: false)
                }
                lastFocusedCueID = nil
                return
            }
            let alreadySelected = (map.selectedAnnotations.first as? CuePointAnnotation)?.cue.id == id
            if lastFocusedCueID == id, alreadySelected { return }
            lastFocusedCueID = id

            // 화면 밖이거나 가장자리면 중심을 이동 (10% 인셋)
            let mapPoint = MKMapPoint(annotation.coordinate)
            let rect = map.visibleMapRect
            let inset = rect.insetBy(dx: rect.size.width * 0.1, dy: rect.size.height * 0.1)
            if !inset.contains(mapPoint) {
                map.setCenter(annotation.coordinate, animated: true)
            }
            map.selectAnnotation(annotation, animated: true)
        }

        // MARK: 드래그 구간 동기화

        func syncRangeSelection(in map: MKMapView, selection: ChartRangeSelection?) {
            let sig: String = {
                guard let s = selection, s.lengthKm > 0 else { return "" }
                return String(format: "%.6f|%.6f|%d", s.lowerKm, s.upperKm, s.isDragging ? 1 : 0)
            }()
            guard sig != lastRangeSignature else { return }
            lastRangeSignature = sig

            if let line = rangePolyline { map.removeOverlay(line) }
            rangePolyline = nil
            if !rangeEndpointAnnotations.isEmpty {
                map.removeAnnotations(rangeEndpointAnnotations)
                rangeEndpointAnnotations = []
            }

            guard let selection, selection.lengthKm > 0 else { return }

            let allPts = draftAllTrackPoints()
            guard allPts.count >= 2 else { return }

            let rangePts = trackPointsInRange(allPts, range: selection)
            guard rangePts.count >= 2 else { return }
            let coords = rangePts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
            let line = RangeSelectionPolyline(coordinates: coords, count: coords.count)
            map.addOverlay(line, level: .aboveRoads)
            rangePolyline = line

            let lo = selection.lowerKm
            let hi = selection.upperKm
            let startInfo = routeHoverInfo(trackPoints: allPts, nearestToDistanceKm: lo)
            let endInfo = routeHoverInfo(trackPoints: allPts, nearestToDistanceKm: hi)
            var anns: [RangeEndpointAnnotation] = []
            if let s = startInfo {
                anns.append(RangeEndpointAnnotation(
                    kind: .start, lat: s.lat, lon: s.lon,
                    distanceKm: lo, elevationMeters: s.elevationMeters
                ))
            }
            if let e = endInfo {
                anns.append(RangeEndpointAnnotation(
                    kind: .end, lat: e.lat, lon: e.lon,
                    distanceKm: hi, elevationMeters: e.elevationMeters
                ))
            }
            map.addAnnotations(anns)
            rangeEndpointAnnotations = anns
            promoteRangeEndpointAnnotationViews(in: map)
        }

        func syncZoomReset(in map: MKMapView, token: Int) {
            guard token != appliedZoomResetToken else { return }
            appliedZoomResetToken = token
            fitMap(map: map)
        }

        /// 코스 전체 기준 선택 구간이 새로 확정되면 그 구간이 보이도록 카메라를 이동한다.
        func syncCameraRange(in map: MKMapView, selection: ChartRangeSelection?) {
            guard let selection, !selection.isDragging, selection.lengthKm > 0 else {
                lastCameraRangeSignature = ""
                return
            }
            let sig = String(format: "%.6f|%.6f", selection.lowerKm, selection.upperKm)
            guard sig != lastCameraRangeSignature else { return }
            lastCameraRangeSignature = sig

            let rangePts = trackPointsInRange(draft.allCourseTrackPoints, range: selection)
            guard rangePts.count >= 2 else { return }
            var rect = MKMapRect.null
            for pt in rangePts {
                let p = MKMapPoint(CLLocationCoordinate2D(latitude: pt.lat, longitude: pt.lon))
                rect = rect.union(MKMapRect(x: p.x, y: p.y, width: 0, height: 0))
            }
            fitMapCamera(map, to: rect)
        }

        // MARK: 호버 위치 동기화

        func syncHoverLocation(in map: MKMapView, info: RouteHoverInfo?) {
            guard let info else {
                mapMouseHoverActive = false
                removeHoverDot(in: map)
                tooltip.hide()
                return
            }
            updateHoverDot(in: map, info: info)
            // 고도 그래프에서 hover하면 경로 위 지점 옆에 말풍선을 띄운다.
            if !mapMouseHoverActive {
                tooltip.show(in: map, atRoutePointOf: info)
            }
        }

        /// 지도 위 마우스가 경로 가까이 오면 그 지점을 잡아 고도 그래프와 함께 표시한다.
        func handleMouseMoved(in map: HoverMapView, point: CGPoint) {
            guard courseTrackPoints.count >= 2,
                  let projection = nearestProjectionOnMap(
                      map, pts: courseTrackPoints, to: point, breakAfter: courseSectionBreaks
                  ),
                  projection.screenDistance <= Self.hoverHitThreshold,
                  let info = routeHoverInfo(
                      trackPoints: courseTrackPoints,
                      segmentStartIndex: projection.segmentStartIndex,
                      fraction: projection.fraction
                  ) else {
                clearHover(in: map)
                return
            }
            mapMouseHoverActive = true
            hoverInfoBinding?.wrappedValue = info
            updateHoverDot(in: map, info: info)
            tooltip.show(in: map, at: point, info: info)
        }

        func clearHover(in map: MKMapView) {
            let wasMapHover = mapMouseHoverActive
            mapMouseHoverActive = false
            // 경로에서 먼 곳을 지나는 동안 매번 nil을 써서 화면을 다시 그리지 않게 한다.
            if wasMapHover || hoverAnnotation != nil {
                hoverInfoBinding?.wrappedValue = nil
            }
            removeHoverDot(in: map)
            tooltip.hide()
        }

        func removeTooltip() {
            tooltip.remove()
        }

        private static let hoverHitThreshold: CGFloat = 10

        private func updateHoverDot(in map: MKMapView, info: RouteHoverInfo) {
            let coord = CLLocationCoordinate2D(latitude: info.lat, longitude: info.lon)
            if let existing = hoverAnnotation {
                existing.coordinate = coord
            } else {
                let annotation = HoverAnnotation()
                annotation.coordinate = coord
                map.addAnnotation(annotation)
                hoverAnnotation = annotation
            }
        }

        private func removeHoverDot(in map: MKMapView) {
            if let existing = hoverAnnotation {
                map.removeAnnotation(existing)
                hoverAnnotation = nil
            }
        }

        private func rebuildCourseTrack() {
            let sections = draft.allCourseSectionTrackPoints
            courseTrackPoints = sections.flatMap { $0 }
            var breaks = Set<Int>()
            var end = -1
            for points in sections.dropLast() {
                end += points.count
                breaks.insert(end)
            }
            courseSectionBreaks = breaks
        }

        func syncPinnedLocation(in map: MKMapView, distanceKm: Double?) {
            let sig: String = distanceKm.map { String(format: "%.6f", $0) } ?? ""
            guard sig != lastPinnedSignature else { return }
            lastPinnedSignature = sig

            if let existing = pinnedAnnotation {
                map.removeAnnotation(existing)
                pinnedAnnotation = nil
            }
            let shouldReveal = distanceKm != lastRevealedPinnedKm
            lastRevealedPinnedKm = distanceKm

            // 고도표는 코스 전체를 보여 주므로, 선택한 섹션이 아니어도 그 지점을 표시하고 카메라를 옮긴다.
            guard let km = distanceKm,
                  let info = routeHoverInfo(
                      trackPoints: draft.allCourseTrackPoints, nearestToDistanceKm: km
                  ) else { return }
            let annotation = PinnedLocationAnnotation(
                lat: info.lat, lon: info.lon,
                distanceKm: info.distanceKm,
                elevationMeters: info.elevationMeters
            )
            map.addAnnotation(annotation)
            pinnedAnnotation = annotation
            if shouldReveal {
                revealCoordinateIfNeeded(annotation.coordinate, in: map)
            }
        }

        private func fitMap(map: MKMapView) {
            // 보이는 모든 섹션의 점을 포함하는 rect로 fit.
            let visibleSections = draft.sections.filter { !$0.isHidden }
            let allCoords: [CLLocationCoordinate2D] = {
                let segPts = visibleSections.flatMap { section in
                    section.legs.flatMap(\.trackPoints)
                }
                if !segPts.isEmpty {
                    return segPts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                }
                return visibleSections.flatMap(\.routePoints).map {
                    CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                }
            }()
            guard !allCoords.isEmpty else { return }

            var rect = MKMapRect.null
            for coord in allCoords {
                let mp = MKMapPoint(coord)
                rect = rect.union(MKMapRect(x: mp.x, y: mp.y, width: 0, height: 0))
            }
            let padded = rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.15)
            if map.frame.size == .zero {
                DispatchQueue.main.async { map.setVisibleMapRect(padded, animated: true) }
            } else {
                map.setVisibleMapRect(padded, animated: true)
            }
        }

        // MARK: 클릭 핸들러

        @objc func handleLeftClick(_ gesture: NSClickGestureRecognizer) {
            guard let map = mapView else { return }
            let pt = gesture.location(in: map)
            let coord = map.convert(pt, toCoordinateFrom: map)

            // 가린 섹션은 맵에서 편집하지 않는다.
            guard !draft.isSelectedSectionHidden else {
                NSSound.beep()
                return
            }

            let hitRadius: CGFloat = 20

            // RoutePoint 위 클릭 → 무시 (드래그/MKMapView가 처리)
            for ann in map.annotations.compactMap({ $0 as? RoutePointAnnotation }) {
                let annPt = map.convert(ann.coordinate, toPointTo: map)
                if abs(annPt.x - pt.x) < hitRadius && abs(annPt.y - pt.y) < hitRadius { return }
            }

            // CuePoint annotation 위 클릭 → 선택만 (RoutePoint 추가 안 함)
            for ann in map.annotations.compactMap({ $0 as? CuePointAnnotation }) {
                let annPt = map.convert(ann.coordinate, toPointTo: map)
                if abs(annPt.x - pt.x) < hitRadius && abs(annPt.y - pt.y) < hitRadius {
                    onSelectCue(ann.cue.id)
                    return
                }
            }

            // 검색 결과 핀 위 클릭도 무시 (MKMapView 콜아웃이 처리)
            for ann in map.annotations.compactMap({ $0 as? SearchResultAnnotation }) {
                let annPt = map.convert(ann.coordinate, toPointTo: map)
                if abs(annPt.x - pt.x) < hitRadius && abs(annPt.y - pt.y) < hitRadius { return }
            }

            // 임시 pin annotation 위 클릭 → 콜아웃 처리에 위임
            for ann in map.annotations.compactMap({ $0 as? PinnedLocationAnnotation }) {
                let annPt = map.convert(ann.coordinate, toPointTo: map)
                if abs(annPt.x - pt.x) < hitRadius && abs(annPt.y - pt.y) < hitRadius { return }
            }

            // 경로(트랙) 위 클릭 → pin 설정 (RoutePoint 추가하지 않음)
            let allPts = draftAllTrackPoints()
            if let onPinDistance,
               allPts.count >= 2,
               let projection = nearestProjectionOnMap(map, pts: allPts, to: pt),
               projection.screenDistance <= 10,
               let info = routeHoverInfo(
                    trackPoints: allPts,
                    segmentStartIndex: projection.segmentStartIndex,
                    fraction: projection.fraction
               ) {
                onPinDistance(info.distanceKm)
                return
            }

            // 빈 영역 → 큐 포커스 해제 + RoutePoint 추가
            onDeselectFocus()

            let newRP = CourseRoutePoint(lat: coord.latitude, lon: coord.longitude)
            let prevCount = draft.routePoints.count

            if prevCount == 0 {
                draft.appendRoutePoint(newRP)
                builtRouteSignature = ""; refresh()
                return
            }

            let prev = draft.routePoints[prevCount - 1]
            let profile = routingProfile
            let sectionID = draft.selectedSectionID
            isCalculatingBinding.wrappedValue = true
            Task {
                let seg = await OSRMRouter.shared.route(from: prev, to: newRP, profile: profile)
                await MainActor.run {
                    guard draft.selectedSectionID == sectionID else {
                        isCalculatingBinding.wrappedValue = false
                        return
                    }
                    guard draft.routePoints.count == prevCount,
                          draft.routePoints.last?.id == prev.id else {
                        isCalculatingBinding.wrappedValue = false
                        return
                    }
                    draft.appendRoutePoint(newRP, segment: seg)
                    isCalculatingBinding.wrappedValue = false
                    builtRouteSignature = ""; refresh()
                }
            }
        }

        @objc func handleRightClick(_ gesture: NSClickGestureRecognizer) {
            guard let map = mapView else { return }
            let pt = gesture.location(in: map)
            let coord = map.convert(pt, toCoordinateFrom: map)

            // RoutePoint 위 우클릭 → 삭제 메뉴
            let hitRadius: CGFloat = 20
            for ann in map.annotations.compactMap({ $0 as? RoutePointAnnotation }) {
                let annPt = map.convert(ann.coordinate, toPointTo: map)
                if abs(annPt.x - pt.x) < hitRadius && abs(annPt.y - pt.y) < hitRadius {
                    showDeleteMenu(for: ann, in: map)
                    return
                }
            }

            // 경로 위인지 확인 (500m 이내)
            let allPts = draftAllTrackPoints()
            let onRoute: (lat: Double, lon: Double, cumKm: Double)? = {
                guard !allPts.isEmpty,
                      let ni = Geo.nearestIndex(allPts, lat: coord.latitude, lon: coord.longitude),
                      Geo.haversineKm(coord.latitude, coord.longitude,
                                      allPts[ni].lat, allPts[ni].lon) < 0.5
                else { return nil }
                return (allPts[ni].lat, allPts[ni].lon, allPts[ni].cumKm)
            }()

            showContextMenu(coord: coord, onRoute: onRoute, in: map)
        }

        private func draftAllTrackPoints() -> [TrackPoint] {
            // CourseEditorDraft.allTrackPoints 가 trackSegments 시그니처로 캐시한다.
            // 여기서 별도 계산하면 매 hover/click 마다 5k+ 포인트를 재순회하게 되므로
            // draft 캐시를 그대로 활용한다. 가린 섹션에는 스냅하지 않는다.
            draft.isSelectedSectionHidden ? [] : draft.allTrackPoints
        }

        private func showDeleteMenu(for ann: RoutePointAnnotation, in map: MKMapView) {
            let menu = NSMenu()
            let item = NSMenuItem(title: "RoutePoint 삭제",
                                   action: #selector(deleteSelectedRoutePoint(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ann
            menu.addItem(item)
            NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: map)
        }

        private func showContextMenu(coord: CLLocationCoordinate2D,
                                     onRoute: (lat: Double, lon: Double, cumKm: Double)?,
                                     in map: MKMapView) {
            let menu = NSMenu()

            // 경로 위일 때만 큐시트 추가
            if let snap = onRoute {
                let splitItem = NSMenuItem(title: "여기서 섹션 분할",
                                           action: #selector(splitSectionFromMenu(_:)), keyEquivalent: "")
                splitItem.target = self
                splitItem.representedObject = CueMenuInfo(
                    snapLat: snap.lat, snapLon: snap.lon, cumKm: snap.cumKm
                )
                menu.addItem(splitItem)

                let cueItem = NSMenuItem(title: "큐시트 추가하기",
                                         action: #selector(addCueFromMenu(_:)), keyEquivalent: "")
                cueItem.target = self
                cueItem.representedObject = CueMenuInfo(snapLat: snap.lat, snapLon: snap.lon, cumKm: snap.cumKm)
                menu.addItem(cueItem)
                menu.addItem(.separator())
            }

            // 카카오 검색 (항상)
            let searchItem = NSMenuItem(title: "이 위치에서 카카오 검색",
                                        action: #selector(kakaoSearchHere(_:)), keyEquivalent: "")
            searchItem.target = self
            searchItem.representedObject = coord
            menu.addItem(searchItem)

            menu.addItem(.separator())

            // 카카오맵에서 보기
            let mapItem = NSMenuItem(title: "카카오맵에서 보기",
                                      action: #selector(openKakaoMap(_:)), keyEquivalent: "")
            mapItem.target = self
            mapItem.representedObject = coord
            menu.addItem(mapItem)

            // 카카오맵 로드뷰에서 보기
            let rvItem = NSMenuItem(title: "카카오맵 로드뷰에서 보기",
                                     action: #selector(openKakaoRoadview(_:)), keyEquivalent: "")
            rvItem.target = self
            rvItem.representedObject = coord
            menu.addItem(rvItem)

            menu.addItem(.separator())

            // 구글 맵에서 보기
            let googleMapItem = NSMenuItem(title: "구글 맵에서 보기",
                                           action: #selector(openGoogleMap(_:)), keyEquivalent: "")
            googleMapItem.target = self
            googleMapItem.representedObject = coord
            menu.addItem(googleMapItem)

            // 구글 맵에서 로드뷰 보기
            let googleRoadviewItem = NSMenuItem(title: "구글 맵에서 로드뷰 보기",
                                                action: #selector(openGoogleRoadview(_:)), keyEquivalent: "")
            googleRoadviewItem.target = self
            googleRoadviewItem.representedObject = coord
            menu.addItem(googleRoadviewItem)

            NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: map)
        }

        @objc private func deleteSelectedRoutePoint(_ sender: NSMenuItem) {
            guard let ann = sender.representedObject as? RoutePointAnnotation else { return }
            let idx = ann.routeIndex
            guard idx < draft.routePoints.count else { return }

            let prevRP = idx > 0 ? draft.routePoints[idx - 1] : nil
            let currRP = draft.routePoints[idx]
            let nextRP = idx < draft.routePoints.count - 1 ? draft.routePoints[idx + 1] : nil
            let sectionID = draft.selectedSectionID
            Task {
                if let p = prevRP { await OSRMRouter.shared.invalidate(from: p, to: currRP) }
                if let n = nextRP { await OSRMRouter.shared.invalidate(from: currRP, to: n) }
            }

            // 중간 삭제이면 인접 구간 재계산
            if let prev = prevRP, let next = nextRP {
                let profile = routingProfile
                let legs = draft.sections[draft.selectedSectionIndex].legs
                let joiningKind: CourseLeg.Kind = (
                    legs[idx - 1].kind == .straight || legs[idx].kind == .straight
                ) ? .straight : .routed
                isCalculatingBinding.wrappedValue = joiningKind == .routed
                Task {
                    let segment = joiningKind == .straight
                        ? Self.straightSegment(from: prev, to: next)
                        : await OSRMRouter.shared.route(from: prev, to: next, profile: profile)
                    await MainActor.run {
                        guard draft.selectedSectionID == sectionID else {
                            isCalculatingBinding.wrappedValue = false
                            return
                        }
                        guard draft.routePoints.indices.contains(idx),
                              draft.routePoints[idx].id == currRP.id else {
                            isCalculatingBinding.wrappedValue = false
                            return
                        }
                        draft.removeRoutePoint(
                            at: idx,
                            joiningSegment: segment,
                            joiningKind: joiningKind
                        )
                        isCalculatingBinding.wrappedValue = false
                        builtRouteSignature = ""; refresh()
                    }
                }
            } else {
                draft.removeRoutePoint(at: idx)
                builtRouteSignature = ""; refresh()
            }
        }

        @objc private func kakaoSearchHere(_ sender: NSMenuItem) {
            guard let map = mapView else { return }
            onSearchInVisibleRect(map.visibleMapRect)
        }

        @objc private func splitSectionFromMenu(_ sender: NSMenuItem) {
            guard let info = sender.representedObject as? CueMenuInfo,
                  draft.splitSelectedSection(atDistanceKm: info.cumKm) else {
                NSSound.beep()
                return
            }
            builtRouteSignature = ""
            refresh()
        }

        @objc private func openKakaoMap(_ sender: NSMenuItem) {
            guard let coord = sender.representedObject as? CLLocationCoordinate2D else { return }
            NSWorkspace.shared.open(KakaoLocalSearch.webURL(lat: coord.latitude, lon: coord.longitude))
        }

        @objc private func openKakaoRoadview(_ sender: NSMenuItem) {
            guard let coord = sender.representedObject as? CLLocationCoordinate2D else { return }
            NSWorkspace.shared.open(KakaoLocalSearch.roadvewURL(lat: coord.latitude, lon: coord.longitude))
        }

        @objc private func openGoogleMap(_ sender: NSMenuItem) {
            guard let coord = sender.representedObject as? CLLocationCoordinate2D else { return }
            NSWorkspace.shared.open(GoogleMapsLink.webURL(lat: coord.latitude, lon: coord.longitude))
        }

        @objc private func openGoogleRoadview(_ sender: NSMenuItem) {
            guard let coord = sender.representedObject as? CLLocationCoordinate2D else { return }
            NSWorkspace.shared.open(GoogleMapsLink.roadviewURL(lat: coord.latitude, lon: coord.longitude))
        }

        @objc private func addCueFromMenu(_ sender: NSMenuItem) {
            guard let info = sender.representedObject as? CueMenuInfo else { return }

            let alert = NSAlert()
            alert.messageText = "큐시트 추가"
            alert.addButton(withTitle: "추가")
            alert.addButton(withTitle: "취소")

            let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
            stack.orientation = .vertical; stack.spacing = 8
            let nameField = NSTextField(frame: .zero)
            nameField.placeholderString = "이름"
            let typePopup = NSPopUpButton()
            for t in cuePointTypes { typePopup.addItem(withTitle: t.label) }
            typePopup.selectItem(withTitle: cuePointLabel(for: "Straight"))
            stack.addArrangedSubview(nameField)
            stack.addArrangedSubview(typePopup)
            alert.accessoryView = stack

            guard alert.runModal() == .alertFirstButtonReturn else { return }

            let selectedLabel = typePopup.titleOfSelectedItem ?? ""
            let selectedValue = cuePointTypes.first { $0.label == selectedLabel }?.value ?? "Straight"
            let cue = CourseCuePoint(lat: info.snapLat, lon: info.snapLon,
                                     name: nameField.stringValue,
                                     pointType: selectedValue,
                                     notes: "",
                                     distanceMeters: info.cumKm * 1000)
            draft.appendCuePoint(cue)
            builtRouteSignature = ""; refresh()
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let rp = annotation as? RoutePointAnnotation {
                let v = MKAnnotationView(annotation: annotation, reuseIdentifier: "routePoint")
                v.image = RoutePointAnnotation.image(for: rp.routeIndex + 1)
                v.centerOffset = .zero
                v.isDraggable = true
                v.canShowCallout = false
                return v
            }
            if let cp = annotation as? CuePointAnnotation {
                let v = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "cuePoint")
                let glyph = cuePointGlyph(for: cp.cue.pointType)
                v.markerTintColor = glyph.color
                if let text = glyph.text {
                    v.glyphText = text
                } else if let symbol = glyph.symbol {
                    v.glyphImage = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                }
                v.canShowCallout = true
                v.titleVisibility = .visible
                return v
            }
            if let range = annotation as? RangeEndpointAnnotation {
                let identifier = range.kind == .start ? "rangeStart" : "rangeEnd"
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                let label = range.kind == .start ? "구간 시작" : "구간 종료"
                let labelText = "\(label) · \(formatRouteDistance(range.distanceKm)) · \(formatRouteElevation(range.elevationMeters))"
                let image = Self.rangeEndpointImage(text: labelText)
                v.annotation = annotation
                v.image = image
                v.centerOffset = CGPoint(x: 0, y: -image.size.height / 2)
                configureRangeEndpointAnnotationViewAsTopMost(v)
                return v
            }
            if annotation is SearchResultAnnotation {
                let v = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "searchResult")
                v.markerTintColor = .systemPink
                v.glyphImage = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
                v.canShowCallout = true
                v.titleVisibility = .visible
                return v
            }
            if annotation is HoverAnnotation {
                // 마우스 바로 밑에 놓이므로 클릭을 가로채지 않게 해, 밑의 RoutePoint 드래그·큐 선택이 그대로 되게 한다.
                let identifier = "hoverPoint"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? ClickThroughAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.image = Self.hoverDotImage
                view.displayPriority = .required
                view.canShowCallout = false
                view.isEnabled = false
                view.zPriority = .max
                return view
            }
            if annotation is PinnedLocationAnnotation {
                let identifier = "pinnedLocation"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.image = Self.pinnedDotImage
                view.displayPriority = .required
                view.canShowCallout = true
                view.zPriority = .max
                return view
            }
            return nil
        }

        private static let hoverDotImage: NSImage = makeHoverDotImage()
        private static let pinnedDotImage: NSImage = makePinnedDotImage()

        func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView,
                     didChange newState: MKAnnotationView.DragState,
                     fromOldState oldState: MKAnnotationView.DragState) {
            guard let ann = view.annotation as? RoutePointAnnotation else { return }
            if newState == .starting { draggingIndex = ann.routeIndex }
            if newState == .ending || newState == .canceling {
                guard let idx = draggingIndex else { return }
                draggingIndex = nil

                let newCoord = ann.coordinate
                let oldRP = draft.routePoints[idx]
                Task {
                    if idx > 0 { await OSRMRouter.shared.invalidate(from: draft.routePoints[idx-1], to: oldRP) }
                    if idx < draft.routePoints.count - 1 { await OSRMRouter.shared.invalidate(from: oldRP, to: draft.routePoints[idx+1]) }
                }

                let newRP = CourseRoutePoint(lat: newCoord.latitude, lon: newCoord.longitude)
                let profile = routingProfile
                let sectionID = draft.selectedSectionID
                let routePoints = draft.routePoints
                let currentSegments = draft.trackSegments
                let currentLegKinds = draft.sections[draft.selectedSectionIndex].legs.map(\.kind)
                isCalculatingBinding.wrappedValue = true
                Task {
                    var segs = currentSegments
                    if idx > 0 && idx - 1 < segs.count {
                        segs[idx - 1] = currentLegKinds[idx - 1] == .straight
                            ? Self.straightSegment(from: routePoints[idx - 1], to: newRP)
                            : await OSRMRouter.shared.route(
                                from: routePoints[idx - 1], to: newRP, profile: profile
                            )
                    }
                    if idx < routePoints.count - 1 && idx < segs.count {
                        segs[idx] = currentLegKinds[idx] == .straight
                            ? Self.straightSegment(from: newRP, to: routePoints[idx + 1])
                            : await OSRMRouter.shared.route(
                                from: newRP, to: routePoints[idx + 1], profile: profile
                            )
                    }
                    await MainActor.run {
                        guard draft.selectedSectionID == sectionID else {
                            isCalculatingBinding.wrappedValue = false
                            return
                        }
                        guard draft.routePoints.indices.contains(idx),
                              draft.routePoints[idx].id == oldRP.id else {
                            isCalculatingBinding.wrappedValue = false
                            return
                        }
                        draft.moveRoutePoint(at: idx, to: newRP, updatedSegments: segs)
                        isCalculatingBinding.wrappedValue = false
                        builtRouteSignature = ""; refresh()
                    }
                }
            }
        }

        private static func straightSegment(
            from: CourseRoutePoint,
            to: CourseRoutePoint
        ) -> [TrackPointCodable] {
            [
                TrackPointCodable(lat: from.lat, lon: from.lon, ele: nil, cumKm: 0),
                TrackPointCodable(
                    lat: to.lat, lon: to.lon, ele: nil,
                    cumKm: Geo.haversineKm(from.lat, from.lon, to.lat, to.lon)
                ),
            ]
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard let cue = view.annotation as? CuePointAnnotation else { return }
            // 동일 cue를 syncFocusedCue가 다시 select하는 경우 콜백 발생을 피한다.
            if lastFocusedCueID == cue.cue.id { return }
            lastFocusedCueID = cue.cue.id
            onSelectCue(cue.cue.id)
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            if views.contains(where: { $0.annotation is RangeEndpointAnnotation }) || !rangeEndpointAnnotations.isEmpty {
                promoteRangeEndpointAnnotationViews(in: mapView)
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tiles = overlay as? GarminTileOverlay {
                return GarminMapRenderer(overlay: tiles, mapView: mapView)
            }
            if let unpaved = overlay as? CourseUnpavedMultiPolyline {
                return CourseUnpavedMultiPolyline.renderer(for: unpaved, routeWidth: routeLineWidth)
            }
            if let poly = overlay as? RangeSelectionPolyline {
                let r = MKPolylineRenderer(polyline: poly)
                r.strokeColor = NSColor.systemIndigo
                r.lineWidth = 6
                r.lineCap = .round; r.lineJoin = .round
                return r
            }
            if let poly = overlay as? SegmentPolyline {
                let r = MKPolylineRenderer(polyline: poly)
                // 섹션마다 지정한 색으로 그린다. 선택 여부로 흐리게 하거나 굵기를 바꾸지 않는다.
                r.strokeColor = poly.color
                r.lineWidth = routeLineWidth
                if poly.kind == .straight {
                    r.lineDashPattern = [7, 5]
                }
                r.lineCap = .round; r.lineJoin = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        // MARK: 구간 끝점 라벨 이미지 (RouteMapView와 동일 디자인)

        static func rangeEndpointImage(text: String) -> NSImage {
            let bg = NSColor.systemIndigo
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let textSize = (text as NSString).size(withAttributes: attrs)
            let width = ceil(textSize.width) + 18
            let size = NSSize(width: width, height: 30)
            let image = NSImage(size: size)
            image.lockFocus()
            let midX = size.width / 2
            let pointer = NSBezierPath()
            pointer.move(to: NSPoint(x: midX, y: 0))
            pointer.line(to: NSPoint(x: midX - 6, y: 7))
            pointer.line(to: NSPoint(x: midX + 6, y: 7))
            pointer.close()
            bg.setFill()
            pointer.fill()
            let pillRect = NSRect(x: 1, y: 7, width: size.width - 2, height: 22)
            let pill = NSBezierPath(roundedRect: pillRect, xRadius: 6, yRadius: 6)
            bg.setFill()
            pill.fill()
            NSColor.white.withAlphaComponent(0.85).setStroke()
            pill.lineWidth = 1
            pill.stroke()
            let tRect = NSRect(
                x: (size.width - textSize.width) / 2,
                y: pillRect.midY - textSize.height / 2,
                width: textSize.width, height: textSize.height
            )
            (text as NSString).draw(in: tRect, withAttributes: attrs)
            image.unlockFocus()
            return image
        }
    }
}

// MARK: - 헬퍼 클래스

final class RoutePointAnnotation: MKPointAnnotation {
    var routeIndex: Int
    var routePoint: CourseRoutePoint

    init(routePoint: CourseRoutePoint, index: Int) {
        self.routePoint = routePoint
        self.routeIndex = index
        super.init()
        coordinate = CLLocationCoordinate2D(latitude: routePoint.lat, longitude: routePoint.lon)
        title = "P\(index + 1)"
    }

    /// 숫자가 표시된 작은 원형 핀 이미지 (지름 22pt)
    static func image(for number: Int) -> NSImage {
        let size = CGSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            // 원 배경
            NSColor.systemBlue.withAlphaComponent(0.9).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            // 테두리
            NSColor.white.setStroke()
            let border = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            border.lineWidth = 1.5
            border.stroke()
            // 숫자
            let label = "\(number)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: number < 10 ? 10 : 8),
                .foregroundColor: NSColor.white,
            ]
            let str = NSAttributedString(string: label, attributes: attrs)
            let strSize = str.size()
            str.draw(at: NSPoint(x: (size.width - strSize.width) / 2,
                                 y: (size.height - strSize.height) / 2))
            return true
        }
        return image
    }
}

final class CuePointAnnotation: MKPointAnnotation {
    var cue: CourseCuePoint
    init(cue: CourseCuePoint) {
        self.cue = cue
        super.init()
        coordinate = CLLocationCoordinate2D(latitude: cue.lat, longitude: cue.lon)
        title = cue.name.isEmpty ? cuePointLabel(for: cue.pointType) : cue.name
    }
}

final class SegmentPolyline: MKPolyline {
    var kind: CourseLeg.Kind = .routed
    var color: NSColor = SectionPalette.nsColor(nil)
}

extension SectionPalette {
    /// 팔레트 hex를 맵·스와치용 색으로 바꾼다. 형식이 틀리면 기본색.
    static func nsColor(_ hex: String?) -> NSColor {
        let c = rgb(fromHex: hex) ?? rgb(fromHex: defaultHex) ?? (0, 0.48, 1)
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
}

private struct CueMenuInfo {
    let snapLat, snapLon, cumKm: Double
}

final class SearchResultAnnotation: MKPointAnnotation {
    let result: KakaoLocalResult
    init(result: KakaoLocalResult) {
        self.result = result
        super.init()
        coordinate = CLLocationCoordinate2D(latitude: result.lat, longitude: result.lon)
        title = result.name
        subtitle = result.address.isEmpty ? result.category : result.address
    }
}
