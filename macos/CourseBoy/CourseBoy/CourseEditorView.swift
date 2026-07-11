import SwiftUI
import MapKit
import CourseBoyKit

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

    // 카카오 검색
    @State private var searchQuery = ""
    @State private var searchResults: [KakaoLocalResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var mapViewRef: MKMapView?   // 맵 뷰 직접 참조 (검색 시 visible rect 조회용)

    @AppStorage(MapStyleStorageKey.editor) private var mapStyleRaw: String = MapStyleOption.standard.rawValue
    @AppStorage(RouteProfileStorageKey.editor) private var routeProfileRaw: String = OSRMRouteProfile.defaultProfile.rawValue

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

    private var titleBinding: Binding<String> {
        Binding(
            get: { draft.title },
            set: { draft.updateTitle($0) }
        )
    }

    init(course: CourseRecord, onSave: (() -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        self.course = course
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: CourseEditorDraft(from: course))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            NavigationSplitView {
                CourseEditorCuesheetSidebar(
                    draft: draft,
                    selectedCueID: $selectedCueID,
                    pinnedDistanceKm: $pinnedDistanceKm,
                    onEditCue: { editingCueID = $0 }
                )
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            } detail: {
                detailPane
                    .inspector(isPresented: $isInspectorPresented) {
                        Group {
                            if rangeSelection != nil || pinnedDistanceKm != nil {
                                VStack(spacing: 0) {
                                    SelectionInspectorStack(
                                        trackPoints: draft.allCourseTrackPoints,
                                        rangeSelection: rangeSelection,
                                        pinnedDistanceKm: pinnedDistanceKm,
                                        onClearRange: { rangeSelection = nil },
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
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
                    }
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
            Divider()
            editorActionBar
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
        .focusedSceneValue(\.courseFileCommandHandler, CourseFileCommandHandler(
            exportTCX: { saveDraftTCX() },
            canExportTCX: !draft.allCourseTrackPoints.isEmpty && draft.hasValidTitle
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

    private var selectedSectionMapPinKm: Double? {
        pinnedDistanceKm.flatMap {
            draft.selectedSectionLocalDistanceKm(forCourseDistanceKm: $0)
        }
    }

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
                    hoverInfo: hoverInfo,
                    pinnedDistanceKm: selectedSectionMapPinKm,
                    mapStyle: mapStyle.wrappedValue,
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
                MapStylePicker(selection: mapStyle)
                    .padding(8)
            }
            .frame(minHeight: 200)
            elevationPane
                .frame(minHeight: 120)
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
                onAddCueAtHover: { km in
                    addCueFromElevation(distanceKm: km, trackPoints: pts)
                },
                onBackgroundClick: { selectedCueID = nil }
            )
        }
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
                cuePoints: applyExportOptions(options, to: draft.allCourseCuePoints)
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

    private var toolbar: some View {
        HStack(spacing: 12) {
            // Undo / Redo — draft.undoCount를 읽어 canUndo/canRedo 변화 시 재렌더링
            let _ = draft.undoCount
            HStack(spacing: 4) {
                Button {
                    draft.undoManager.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!draft.undoManager.canUndo)
                .help(draft.undoManager.canUndo ? "실행 취소: \(draft.undoManager.undoActionName)" : "실행 취소")
                .keyboardShortcut("z", modifiers: .command)

                Button {
                    draft.undoManager.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!draft.undoManager.canRedo)
                .help(draft.undoManager.canRedo ? "다시 실행: \(draft.undoManager.redoActionName)" : "다시 실행")
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 20)

            courseTitleField

            Divider().frame(height: 20)

            RouteProfilePicker(selection: routeProfile)

            Divider().frame(height: 20)

            // 카카오 검색
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("장소 검색 (화면 범위)", text: $searchQuery)
                    .textFieldStyle(.plain)
                    .frame(width: 200)
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
                } else {
                    Button {
                        triggerSearch()
                    } label: {
                        Image(systemName: "arrow.right.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 7))
            .help(searchError ?? "카카오 로컬 검색")

            Spacer()

            InspectorToggleButton(isPresented: $isInspectorPresented)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var editorActionBar: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("취소") {
                if draft.hasChanges {
                    showDiscardConfirm = true
                } else {
                    closeEditor()
                }
            }
            .keyboardShortcut(.escape, modifiers: [])

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
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var courseTitleField: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.cursor")
                .foregroundStyle(.secondary)

            TextField("코스 제목", text: titleBinding)
                .textFieldStyle(.plain)
                .font(.headline)
                .lineLimit(1)
                .frame(width: 240)
                .onSubmit {
                    if draft.hasValidTitle {
                        draft.updateTitle(draft.normalizedTitle)
                    }
                }

            if !draft.hasValidTitle {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("코스 제목을 입력하세요")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 7))
        .help(draft.hasValidTitle ? "코스 제목" : "코스 제목을 입력하세요")
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

                Button {
                    draft.addSection()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("섹션 추가")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(draft.sections.enumerated()), id: \.element.id) { index, section in
                        Button {
                            draft.selectSection(section.id)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: draft.selectedSectionID == section.id
                                      ? "circle.inset.filled" : "circle")
                                    .foregroundStyle(draft.selectedSectionID == section.id ? .blue : .secondary)
                                Text("섹션 \(index + 1)")
                                Spacer()
                                Text(formatRouteDistance(section.distanceKm))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                draft.selectedSectionID == section.id
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                draft.selectSection(section.id)
                                if let courseKm = pinnedDistanceKm,
                                   let km = draft.selectedSectionLocalDistanceKm(
                                    forCourseDistanceKm: courseKm
                                   ) {
                                    _ = draft.splitSelectedSection(atDistanceKm: km)
                                }
                            } label: {
                                Label("고정 지점에서 분할", systemImage: "scissors")
                            }
                            .disabled(
                                draft.selectedSectionID != section.id || selectedPinnedLocalKm == nil
                            )

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
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(maxHeight: 180)
        }
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
        progress.stats(at: Geo.nearestIndex(pts, lat: cue.lat, lon: cue.lon))
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
            guard cue.lat != 0 || cue.lon != 0,
                  let idx = Geo.nearestIndex(trackPoints, lat: cue.lat, lon: cue.lon) else {
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(draft.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
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
        let cueIdx = Geo.nearestIndex(pts, lat: cue.lat, lon: cue.lon)
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
        if let idx = Geo.nearestIndex(pts, lat: cue.lat, lon: cue.lon) {
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
        guard let aIdx = Geo.nearestIndex(pts, lat: a.lat, lon: a.lon),
              let bIdx = Geo.nearestIndex(pts, lat: b.lat, lon: b.lon),
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
    var hoverInfo: RouteHoverInfo?
    var pinnedDistanceKm: Double?
    var mapStyle: MapStyleOption = .standard
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

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
        applyMapStyle(mapStyle, to: map)
        context.coordinator.appliedMapStyle = mapStyle
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
        if context.coordinator.appliedMapStyle != mapStyle {
            applyMapStyle(mapStyle, to: map)
            context.coordinator.appliedMapStyle = mapStyle
        }
        context.coordinator.draft = draft
        context.coordinator.onSelectCue = onSelectCue
        context.coordinator.onDeselectFocus = onDeselectFocus
        context.coordinator.onPinDistance = onPinDistance
        context.coordinator.onSearchInVisibleRect = onSearchInVisibleRect
        context.coordinator.routingProfile = routingProfile
        context.coordinator.refresh()
        context.coordinator.updateSearchAnnotations(map: map, results: searchResults)
        context.coordinator.syncFocusedCue(in: map, focusedID: selectedCueID)
        context.coordinator.syncRangeSelection(in: map, selection: rangeSelection)
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
        var appliedMapStyle: MapStyleOption?
        weak var mapView: MKMapView?

        private var draggingIndex: Int?
        private var needsFitOnFirstLoad = true
        private var builtRouteSignature: String = ""
        private var builtSearchSignature: String = ""
        private var lastFocusedCueID: UUID?
        private var rangePolyline: RangeSelectionPolyline?
        private var rangeEndpointAnnotations: [RangeEndpointAnnotation] = []
        private var lastRangeSignature: String = ""
        private var hoverAnnotation: HoverAnnotation?
        private var pinnedAnnotation: PinnedLocationAnnotation?
        private var lastPinnedSignature: String = ""

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
                    return "\(leg.kind.rawValue):\(leg.trackPoints.count):\(first?.lat ?? 0),\(first?.lon ?? 0):\(last?.lat ?? 0),\(last?.lon ?? 0)"
                }.joined(separator: ",")
                return "\(section.id):\(legs)"
            }.joined(separator: "|") + "#active=\(draft.selectedSectionID)"
            let cueSig = draft.cuePoints.map { "\($0.id):\($0.lat),\($0.lon),\($0.pointType),\($0.name)" }.joined(separator: "|")
            let sig = routeSig + "##" + cueSig
            guard sig != builtRouteSignature else { return }
            builtRouteSignature = sig

            map.removeOverlays(map.overlays)
            let routeAnns = map.annotations.compactMap { $0 as? RoutePointAnnotation }
            let cueAnns = map.annotations.compactMap { $0 as? CuePointAnnotation }
            map.removeAnnotations(routeAnns + cueAnns)

            // RoutePoint 핸들은 활성 섹션에만 표시한다.
            for (i, rp) in draft.routePoints.enumerated() {
                map.addAnnotation(RoutePointAnnotation(routePoint: rp, index: i))
            }
            for section in draft.sections {
                for leg in section.legs {
                    guard leg.trackPoints.count >= 2 else { continue }
                    let coords = leg.trackPoints.map {
                        CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon)
                    }
                    let polyline = SegmentPolyline(coordinates: coords, count: coords.count)
                    polyline.kind = leg.kind
                    polyline.isActiveSection = section.id == draft.selectedSectionID
                    map.addOverlay(polyline, level: .aboveRoads)
                }
            }
            for cue in draft.cuePoints where cue.lat != 0 || cue.lon != 0 {
                map.addAnnotation(CuePointAnnotation(cue: cue))
            }

            // refresh로 cue annotation을 새로 만들었으니, 선택 동기화 트리거
            lastFocusedCueID = nil
            // range overlay는 syncRangeSelection이 별도로 다시 만든다.
            lastRangeSignature = ""
            hoverAnnotation = nil
            pinnedAnnotation = nil
            lastPinnedSignature = ""

            if needsFitOnFirstLoad && draft.sections.contains(where: { !$0.routePoints.isEmpty }) {
                needsFitOnFirstLoad = false
                fitMap(map: map)
            }
        }

        // MARK: 검색 결과 어노테이션

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

        // MARK: 호버 위치 동기화

        func syncHoverLocation(in map: MKMapView, info: RouteHoverInfo?) {
            guard let info else {
                if let existing = hoverAnnotation {
                    map.removeAnnotation(existing)
                    hoverAnnotation = nil
                }
                return
            }
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

        func syncPinnedLocation(in map: MKMapView, distanceKm: Double?) {
            let sig: String = distanceKm.map { String(format: "%.6f", $0) } ?? ""
            guard sig != lastPinnedSignature else { return }
            lastPinnedSignature = sig

            if let existing = pinnedAnnotation {
                map.removeAnnotation(existing)
                pinnedAnnotation = nil
            }
            guard let km = distanceKm else { return }
            let allPts = draftAllTrackPoints()
            guard let info = routeHoverInfo(trackPoints: allPts, nearestToDistanceKm: km) else { return }
            let annotation = PinnedLocationAnnotation(
                lat: info.lat, lon: info.lon,
                distanceKm: info.distanceKm,
                elevationMeters: info.elevationMeters
            )
            map.addAnnotation(annotation)
            pinnedAnnotation = annotation
        }

        private func fitMap(map: MKMapView) {
            // 모든 섹션의 점을 포함하는 rect로 fit.
            let allCoords: [CLLocationCoordinate2D] = {
                let segPts = draft.sections.flatMap { section in
                    section.legs.flatMap(\.trackPoints)
                }
                if !segPts.isEmpty {
                    return segPts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                }
                return draft.sections.flatMap(\.routePoints).map {
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
            // draft 캐시를 그대로 활용한다.
            draft.allTrackPoints
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
                let identifier = "hoverPoint"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: identifier)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: identifier)
                view.annotation = annotation
                view.image = Self.hoverDotImage
                view.displayPriority = .required
                view.canShowCallout = false
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
            if let poly = overlay as? RangeSelectionPolyline {
                let r = MKPolylineRenderer(polyline: poly)
                r.strokeColor = NSColor.systemIndigo
                r.lineWidth = 6
                r.lineCap = .round; r.lineJoin = .round
                return r
            }
            if let poly = overlay as? SegmentPolyline {
                let r = MKPolylineRenderer(polyline: poly)
                if poly.kind == .straight {
                    r.strokeColor = NSColor.systemOrange
                    r.lineDashPattern = [7, 5]
                    r.lineWidth = poly.isActiveSection ? 4 : 3
                } else {
                    r.strokeColor = poly.isActiveSection
                        ? NSColor.systemBlue
                        : NSColor.secondaryLabelColor.withAlphaComponent(0.55)
                    r.lineWidth = poly.isActiveSection ? 4 : 2.5
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
    var isActiveSection = true
}
final class CuePolyline: MKPolyline {}

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
