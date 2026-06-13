import SwiftUI
import MapKit
import StravaTCXKit

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
    var course: CourseRecord
    @Environment(\.dismiss) private var dismiss

    @State private var draft: CourseEditorDraft
    @State private var isCalculating = false
    @State private var showDiscardConfirm = false
    @State private var closeConfirmed = false
    @State private var hoverInfo: RouteHoverInfo?
    @State private var selectedCueID: UUID?
    @State private var rangeSelection: ChartRangeSelection?

    // 카카오 검색
    @State private var searchQuery = ""
    @State private var searchResults: [KakaoLocalResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var mapViewRef: MKMapView?   // 맵 뷰 직접 참조 (검색 시 visible rect 조회용)

    @AppStorage(MapStyleStorageKey.editor) private var mapStyleRaw: String = MapStyleOption.standard.rawValue

    private var mapStyle: Binding<MapStyleOption> {
        Binding(
            get: { MapStyleOption(rawValue: mapStyleRaw) ?? .standard },
            set: { mapStyleRaw = $0.rawValue }
        )
    }

    init(course: CourseRecord) {
        self.course = course
        _draft = State(initialValue: CourseEditorDraft(from: course))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            NavigationSplitView {
                CourseEditorCuesheetSidebar(draft: draft, selectedCueID: $selectedCueID)
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            } detail: {
                detailPane
                    .inspector(isPresented: .constant(true)) {
                        Group {
                            if let range = rangeSelection {
                                CourseEditorRangeInspectorView(
                                    draft: draft,
                                    trackPoints: draft.allTrackPoints,
                                    range: range,
                                    onAddSegment: { addSegmentFromRange(range) }
                                )
                            } else {
                                CourseEditorCueInspectorView(
                                    draft: draft,
                                    selectedCueID: selectedCueID
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
        }
        .onChange(of: draft.cuePoints.map(\.id)) { _, ids in
            if let sel = selectedCueID, !ids.contains(sel) {
                selectedCueID = nil
            }
        }
        .focusedSceneValue(\.courseFileCommandHandler, CourseFileCommandHandler(
            saveTCX: { saveDraftTCX() },
            canSaveTCX: !draft.allTrackPoints.isEmpty
        ))
        .confirmationDialog("변경 사항을 버리시겠습니까?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("변경 사항 버리기", role: .destructive) { closeConfirmed = true }
            Button("계속 편집", role: .cancel) {}
        } message: {
            Text("저장하지 않은 변경 사항은 모두 사라집니다.")
        }
        .onChange(of: closeConfirmed) { _, confirmed in
            if confirmed {
                dismiss()
                NSApp.keyWindow?.close()
            }
        }
    }

    // MARK: - 가운데 컨텐츠 (지도 + 고도그래프)

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
                    rangeSelection: rangeSelection,
                    mapStyle: mapStyle.wrappedValue,
                    onSelectCue: { selectedCueID = $0 },
                    onDeselectFocus: { selectedCueID = nil },
                    onSearchInVisibleRect: { rect in
                        performSearch(in: rect)
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
        let pts = draft.allTrackPoints
        if pts.isEmpty {
            ContentUnavailableView {
                Label("고도 데이터 없음", systemImage: "chart.xyaxis.line")
            } description: {
                Text("경로를 추가하면 고도 그래프가 표시됩니다.")
            }
        } else {
            ElevationChartView(
                trackPoints: pts,
                markers: elevationMarkers(for: pts),
                focusedDistanceKm: focusedDistanceKm(for: pts),
                hoverInfo: $hoverInfo,
                rangeSelection: $rangeSelection,
                onAddCueAtHover: { km in
                    addCueFromElevation(distanceKm: km, trackPoints: pts)
                },
                onBackgroundClick: { selectedCueID = nil }
            )
        }
    }

    private func focusedDistanceKm(for pts: [TrackPoint]) -> Double? {
        guard let id = selectedCueID,
              let cue = draft.cuePoints.first(where: { $0.id == id }),
              let idx = Geo.nearestIndex(pts, lat: cue.lat, lon: cue.lon) else { return nil }
        return pts[idx].cumKm
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
            distanceMeters: snap.cumKm * 1000
        )
        draft.appendCuePoint(cue)
    }

    private func saveDraftTCX() {
        do {
            let data = try CourseTCXFileCoder.makeTCXData(
                title: draft.title,
                trackPoints: draft.allTrackPoints,
                cuePoints: draft.cuePoints
            )
            Exporter.saveTCX(filename: draft.title, data: data)
        } catch {
            NSSound.beep()
        }
    }

    private func elevationMarkers(for pts: [TrackPoint]) -> [ElevationMarker] {
        draft.cuePoints.compactMap { cue in
            guard cue.lat != 0 || cue.lon != 0,
                  let idx = Geo.nearestIndex(pts, lat: cue.lat, lon: cue.lon) else { return nil }
            return ElevationMarker(
                id: cue.id.uuidString,
                cumKm: pts[idx].cumKm,
                label: cue.name.isEmpty ? cuePointLabel(for: cue.pointType) : cue.name,
                color: .cyan
            )
        }
    }

    // MARK: - 구간 추가 (드래그 → 시작/종료 큐시트)

    private func addSegmentFromRange(_ range: ChartRangeSelection) {
        let pts = draft.allTrackPoints
        guard let stats = routeRangeStats(trackPoints: pts, range: range) else {
            NSSound.beep(); return
        }
        guard let s = interpolateTrackPoint(in: pts, atDistanceKm: stats.startKm),
              let e = interpolateTrackPoint(in: pts, atDistanceKm: stats.endKm) else {
            NSSound.beep(); return
        }

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
        Task { @MainActor in
            do {
                let results = try await KakaoLocalSearch.search(query: query, in: rect)
                searchResults = results
                if searchResults.isEmpty { searchError = "검색 결과 없음" }
            } catch {
                searchError = error.localizedDescription
                searchResults = []
            }
            isSearching = false
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

            Button("취소") {
                if draft.undoManager.canUndo {
                    showDiscardConfirm = true
                } else {
                    dismiss()
                }
            }
            .keyboardShortcut(.escape, modifiers: [])

            Button("저장") {
                draft.commit(to: course)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - CourseEditorCuesheetSidebar

/// 좌측 큐시트 사이드바. 거리 순으로 정렬, 인라인 편집, 항목 추가/삭제.
private struct CourseEditorCuesheetSidebar: View {
    var draft: CourseEditorDraft
    @Binding var selectedCueID: UUID?

    @State private var showAddSheet = false
    @State private var newName = ""
    @State private var newType = "Straight"

    /// distanceMeters 기준 정렬. 동일 거리에서는 추가 순서를 보존.
    private var sortedCues: [CourseCuePoint] {
        draft.cuePoints.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    var body: some View {
        VStack(spacing: 0) {
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
                        CuePointRow(cue: Binding(
                            get: {
                                draft.cuePoints.first(where: { $0.id == cue.id }) ?? cue
                            },
                            set: { newValue in
                                if let idx = draft.cuePoints.firstIndex(where: { $0.id == cue.id }) {
                                    draft.cuePoints[idx] = newValue
                                }
                            }
                        ))
                        .tag(cue.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                if let idx = draft.cuePoints.firstIndex(where: { $0.id == cue.id }) {
                                    draft.removeCuePoints(at: IndexSet(integer: idx))
                                }
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
    }
}

// MARK: - CuePointRow

private struct CuePointRow: View {
    @Binding var cue: CourseCuePoint

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField("이름", text: $cue.name)
                .font(.body)
                .textFieldStyle(.plain)
            HStack {
                Picker("", selection: $cue.pointType) {
                    ForEach(cuePointPickerTypes(for: cue.pointType), id: \.value) { Text($0.label).tag($0.value) }
                }
                .labelsHidden()
                .frame(maxWidth: 140)
                Spacer()
                if cue.distanceMeters > 0 {
                    Text(String(format: "%.1f km", cue.distanceMeters / 1000))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
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

// MARK: - CourseEditorCueInspectorView

/// 우측 인스펙터: 선택된 큐 상세 정보. 보기 화면 CourseCueInspectorView와 동일 정보 +
/// "삭제" 버튼.
private struct CourseEditorCueInspectorView: View {
    var draft: CourseEditorDraft
    var selectedCueID: UUID?

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
                ContentUnavailableView {
                    Label("큐를 선택하세요", systemImage: "mappin.and.ellipse")
                } description: {
                    Text("좌측 목록에서 큐 항목을 선택하면 상세 정보가 표시됩니다.")
                        .font(.caption)
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
            // 헤더 (이름 + 타입 + 삭제)
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

    private func formatEleDelta(from a: CourseCuePoint, to b: CourseCuePoint, pts: [TrackPoint]) -> String {
        guard let aIdx = Geo.nearestIndex(pts, lat: a.lat, lon: a.lon),
              let bIdx = Geo.nearestIndex(pts, lat: b.lat, lon: b.lon),
              let aEle = pts[aIdx].ele, let bEle = pts[bIdx].ele else { return "—" }
        let diff = bEle - aEle
        let sign = diff > 0 ? "+" : (diff < 0 ? "" : "")
        return String(format: "%@%.0f m", sign, diff)
    }
}

// MARK: - CourseEditorRangeInspectorView

/// 우측 인스펙터 (드래그 구간 선택 시): 구간 통계 + "구간 추가" 버튼.
private struct CourseEditorRangeInspectorView: View {
    var draft: CourseEditorDraft
    var trackPoints: [TrackPoint]
    var range: ChartRangeSelection
    var onAddSegment: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            RangeStatsInspectorView(trackPoints: trackPoints, range: range)
            Divider()
            Button {
                onAddSegment()
            } label: {
                Label("구간 추가", systemImage: "flag.checkered")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(range.lengthKm <= 0 || range.isDragging)
            .padding(12)
        }
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
    var mapStyle: MapStyleOption = .standard
    var onSelectCue: (UUID) -> Void
    var onDeselectFocus: () -> Void
    var onSearchInVisibleRect: (MKMapRect) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(draft: draft, isCalculatingBinding: $isCalculating,
                    searchResultsBinding: $searchResults,
                    onSelectCue: onSelectCue,
                    onDeselectFocus: onDeselectFocus,
                    onSearchInVisibleRect: onSearchInVisibleRect)
    }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
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
        context.coordinator.onSearchInVisibleRect = onSearchInVisibleRect
        context.coordinator.refresh()
        context.coordinator.updateSearchAnnotations(map: map, results: searchResults)
        context.coordinator.syncFocusedCue(in: map, focusedID: selectedCueID)
        context.coordinator.syncRangeSelection(in: map, selection: rangeSelection)
        promoteRangeEndpointAnnotationViews(in: map)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var draft: CourseEditorDraft
        var isCalculatingBinding: Binding<Bool>
        var searchResultsBinding: Binding<[KakaoLocalResult]>
        var onSelectCue: (UUID) -> Void
        var onDeselectFocus: () -> Void
        var onSearchInVisibleRect: (MKMapRect) -> Void
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

        init(draft: CourseEditorDraft, isCalculatingBinding: Binding<Bool>,
             searchResultsBinding: Binding<[KakaoLocalResult]>,
             onSelectCue: @escaping (UUID) -> Void,
             onDeselectFocus: @escaping () -> Void,
             onSearchInVisibleRect: @escaping (MKMapRect) -> Void) {
            self.draft = draft
            self.isCalculatingBinding = isCalculatingBinding
            self.searchResultsBinding = searchResultsBinding
            self.onSelectCue = onSelectCue
            self.onDeselectFocus = onDeselectFocus
            self.onSearchInVisibleRect = onSearchInVisibleRect
        }

        // MARK: 맵 갱신

        func refresh() {
            guard let map = mapView else { return }
            // signature: routePoints + cuePoints (cue 변경 시도 핀 갱신)
            let routeSig = draft.routePoints.map { "\($0.lat),\($0.lon)" }.joined(separator: "|")
            let cueSig = draft.cuePoints.map { "\($0.id):\($0.lat),\($0.lon),\($0.pointType),\($0.name)" }.joined(separator: "|")
            let sig = routeSig + "##" + cueSig
            guard sig != builtRouteSignature else { return }
            builtRouteSignature = sig

            map.removeOverlays(map.overlays)
            let routeAnns = map.annotations.compactMap { $0 as? RoutePointAnnotation }
            let cueAnns = map.annotations.compactMap { $0 as? CuePointAnnotation }
            map.removeAnnotations(routeAnns + cueAnns)

            for (i, rp) in draft.routePoints.enumerated() {
                map.addAnnotation(RoutePointAnnotation(routePoint: rp, index: i))
            }
            for seg in draft.trackSegments {
                guard seg.count >= 2 else { continue }
                let coords = seg.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                map.addOverlay(SegmentPolyline(coordinates: coords, count: coords.count), level: .aboveRoads)
            }
            for cue in draft.cuePoints where cue.lat != 0 || cue.lon != 0 {
                map.addAnnotation(CuePointAnnotation(cue: cue))
            }

            // refresh로 cue annotation을 새로 만들었으니, 선택 동기화 트리거
            lastFocusedCueID = nil
            // range overlay는 syncRangeSelection이 별도로 다시 만든다.
            lastRangeSignature = ""

            if needsFitOnFirstLoad && !draft.routePoints.isEmpty {
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

        private func fitMap(map: MKMapView) {
            // trackSegments의 모든 점을 포함하는 rect로 fit. 없으면 routePoints로 fallback.
            let allCoords: [CLLocationCoordinate2D] = {
                let segPts = draft.trackSegments.flatMap { $0 }
                if !segPts.isEmpty {
                    return segPts.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
                }
                return draft.routePoints.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
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
            isCalculatingBinding.wrappedValue = true
            Task { @MainActor in
                let seg = await OSRMRouter.shared.route(from: prev, to: newRP)
                draft.appendRoutePoint(newRP, segment: seg)
                isCalculatingBinding.wrappedValue = false
                builtRouteSignature = ""; refresh()
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
            var raw: [TrackPointCodable] = []
            for (i, seg) in draft.trackSegments.enumerated() {
                raw.append(contentsOf: i == 0 ? seg : Array(seg.dropFirst()))
            }
            var result: [TrackPoint] = []
            var cumKm: Double = 0
            for (i, tp) in raw.enumerated() {
                if i > 0 { cumKm += Geo.haversineKm(raw[i-1].lat, raw[i-1].lon, tp.lat, tp.lon) }
                result.append(TrackPoint(lat: tp.lat, lon: tp.lon, ele: tp.ele, time: nil, cumKm: cumKm))
            }
            return result
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

            NSMenu.popUpContextMenu(menu, with: NSApp.currentEvent ?? NSEvent(), for: map)
        }

        @objc private func deleteSelectedRoutePoint(_ sender: NSMenuItem) {
            guard let ann = sender.representedObject as? RoutePointAnnotation else { return }
            let idx = ann.routeIndex
            guard idx < draft.routePoints.count else { return }

            let prevRP = idx > 0 ? draft.routePoints[idx - 1] : nil
            let currRP = draft.routePoints[idx]
            let nextRP = idx < draft.routePoints.count - 1 ? draft.routePoints[idx + 1] : nil
            Task {
                if let p = prevRP { await OSRMRouter.shared.invalidate(from: p, to: currRP) }
                if let n = nextRP { await OSRMRouter.shared.invalidate(from: currRP, to: n) }
            }

            draft.removeRoutePoint(at: idx)

            // 중간 삭제이면 인접 구간 재계산
            if idx > 0 && idx < draft.routePoints.count {
                let prev = draft.routePoints[idx - 1]
                let next = draft.routePoints[idx]
                isCalculatingBinding.wrappedValue = true
                Task { @MainActor in
                    var segs = draft.trackSegments
                    let seg = await OSRMRouter.shared.route(from: prev, to: next)
                    let insertAt = idx - 1
                    if insertAt < segs.count { segs.insert(seg, at: insertAt) }
                    else { segs.append(seg) }
                    draft.replaceSegments(segs)
                    isCalculatingBinding.wrappedValue = false
                    builtRouteSignature = ""; refresh()
                }
            } else {
                builtRouteSignature = ""; refresh()
            }
        }

        @objc private func kakaoSearchHere(_ sender: NSMenuItem) {
            guard let map = mapView else { return }
            onSearchInVisibleRect(map.visibleMapRect)
        }

        @objc private func openKakaoMap(_ sender: NSMenuItem) {
            guard let coord = sender.representedObject as? CLLocationCoordinate2D else { return }
            NSWorkspace.shared.open(KakaoLocalSearch.webURL(lat: coord.latitude, lon: coord.longitude))
        }

        @objc private func openKakaoRoadview(_ sender: NSMenuItem) {
            guard let coord = sender.representedObject as? CLLocationCoordinate2D else { return }
            NSWorkspace.shared.open(KakaoLocalSearch.roadvewURL(lat: coord.latitude, lon: coord.longitude))
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
            return nil
        }

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
                isCalculatingBinding.wrappedValue = true
                Task { @MainActor in
                    var segs = draft.trackSegments
                    if idx > 0 && idx - 1 < segs.count {
                        segs[idx - 1] = await OSRMRouter.shared.route(from: draft.routePoints[idx-1], to: newRP)
                    }
                    if idx < draft.routePoints.count - 1 && idx < segs.count {
                        segs[idx] = await OSRMRouter.shared.route(from: newRP, to: draft.routePoints[idx+1])
                    }
                    draft.moveRoutePoint(at: idx, to: newRP, updatedSegments: segs)
                    isCalculatingBinding.wrappedValue = false
                    builtRouteSignature = ""; refresh()
                }
            }
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
                r.strokeColor = NSColor.systemBlue
                r.lineWidth = 3
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

final class SegmentPolyline: MKPolyline {}
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
