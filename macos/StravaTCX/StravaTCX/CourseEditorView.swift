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
    ("Fourth Category", "4등급 오르막"),
    ("Third Category",  "3등급 오르막"),
    ("Second Category", "2등급 오르막"),
    ("First Category",  "1등급 오르막"),
    ("Hors Category",  "HC급 오르막"),
    ("Sprint",         "스프린트 구간"),
]

func cuePointLabel(for value: String) -> String {
    cuePointTypes.first { $0.value == value }?.label ?? value
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
    case "First Category":  return .init(text: "1",  color: .systemYellow)
    case "Second Category": return .init(text: "2",  color: .systemYellow)
    case "Third Category":  return .init(text: "3",  color: .systemYellow)
    case "Fourth Category": return .init(text: "4",  color: .systemYellow)
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

    // 카카오 검색
    @State private var searchQuery = ""
    @State private var searchResults: [KakaoLocalResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var mapViewRef: MKMapView?   // 맵 뷰 직접 참조 (검색 시 visible rect 조회용)
    @State private var pendingSearch = false

    init(course: CourseRecord) {
        self.course = course
        _draft = State(initialValue: CourseEditorDraft(from: course))
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HSplitView {
                VSplitView {
                    CourseEditMapView(draft: draft, isCalculating: $isCalculating,
                                      searchResults: $searchResults,
                                      mapViewRef: $mapViewRef,
                                      onSearchInVisibleRect: { rect in
                        performSearch(in: rect)
                    })
                        .frame(minHeight: 200)
                    elevationPane
                        .frame(minHeight: 120)
                }
                .frame(minWidth: 400)
                CueSheetPanel(draft: draft)
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
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
                hoverInfo: $hoverInfo,
                onAddCueAtHover: { km in
                    addCueFromElevation(distanceKm: km, trackPoints: pts)
                }
            )
        }
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

    private func elevationMarkers(for pts: [TrackPoint]) -> [ElevationMarker] {
        draft.cuePoints.compactMap { cue in
            guard cue.lat != 0 || cue.lon != 0,
                  let idx = Geo.nearestIndex(pts, lat: cue.lat, lon: cue.lon) else { return nil }
            return ElevationMarker(
                id: cue.id.uuidString,
                cumKm: pts[idx].cumKm,
                label: cue.name.isEmpty ? cue.pointType : cue.name,
                color: .cyan
            )
        }
    }

    // MARK: - 카카오 검색

    /// 툴바 엔터/버튼 → 현재 맵 visible rect로 즉시 검색
    private func triggerSearch() {
        print("[Search] triggerSearch called, query='\(searchQuery)', mapViewRef=\(mapViewRef != nil ? "있음" : "nil")")
        searchResults = []
        searchError = nil
        if let map = mapViewRef {
            let rect = map.visibleMapRect
            print("[Search] visibleMapRect=\(rect)")
            performSearch(in: rect)
        } else {
            print("[Search] mapViewRef가 nil — 검색 불가")
        }
    }

    private func performSearch(in rect: MKMapRect) {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        print("[Search] performSearch query='\(query)'")
        guard !query.isEmpty else { print("[Search] 쿼리 비어있음, 종료"); return }
        isSearching = true
        searchError = nil
        Task { @MainActor in
            do {
                print("[Search] API 호출 시작")
                let results = try await KakaoLocalSearch.search(query: query, in: rect)
                print("[Search] 결과 \(results.count)건: \(results.map(\.name))")
                searchResults = results
                if searchResults.isEmpty { searchError = "검색 결과 없음" }
            } catch {
                print("[Search] 오류: \(error)")
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

// MARK: - CueSheetPanel

private struct CueSheetPanel: View {
    var draft: CourseEditorDraft

    @State private var showAddSheet = false
    @State private var newName = ""
    @State private var newType = "Straight"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("큐시트")
                    .font(.headline)
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
                }
            } else {
                List {
                    ForEach(draft.cuePoints.indices, id: \.self) { i in
                        CuePointRow(cue: Binding(
                            get: { draft.cuePoints[i] },
                            set: { draft.cuePoints[i] = $0 }
                        ))
                    }
                    .onDelete { draft.removeCuePoints(at: $0) }
                    .onMove { draft.moveCuePoints(from: $0, to: $1) }
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
            HStack {
                Picker("", selection: $cue.pointType) {
                    ForEach(cuePointTypes, id: \.value) { Text($0.label).tag($0.value) }
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

// MARK: - CourseEditMapView

struct CourseEditMapView: NSViewRepresentable {
    var draft: CourseEditorDraft
    @Binding var isCalculating: Bool
    @Binding var searchResults: [KakaoLocalResult]
    @Binding var mapViewRef: MKMapView?
    var onSearchInVisibleRect: (MKMapRect) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(draft: draft, isCalculatingBinding: $isCalculating,
                    searchResultsBinding: $searchResults,
                    onSearchInVisibleRect: onSearchInVisibleRect)
    }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        map.showsScale = true
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
        context.coordinator.draft = draft
        context.coordinator.onSearchInVisibleRect = onSearchInVisibleRect
        context.coordinator.refresh()
        context.coordinator.updateSearchAnnotations(map: map, results: searchResults)

    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        var draft: CourseEditorDraft
        var isCalculatingBinding: Binding<Bool>
        var searchResultsBinding: Binding<[KakaoLocalResult]>
        var onSearchInVisibleRect: (MKMapRect) -> Void
        weak var mapView: MKMapView?

        private var draggingIndex: Int?
        private var needsFitOnFirstLoad = true
        private var builtRouteSignature: String = ""
        private var builtSearchSignature: String = ""

        init(draft: CourseEditorDraft, isCalculatingBinding: Binding<Bool>,
             searchResultsBinding: Binding<[KakaoLocalResult]>,
             onSearchInVisibleRect: @escaping (MKMapRect) -> Void) {
            self.draft = draft
            self.isCalculatingBinding = isCalculatingBinding
            self.searchResultsBinding = searchResultsBinding
            self.onSearchInVisibleRect = onSearchInVisibleRect
        }

        // MARK: 맵 갱신

        func refresh() {
            guard let map = mapView else { return }
            let sig = draft.routePoints.map { "\($0.lat),\($0.lon)" }.joined(separator: "|")
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
            for ann in map.annotations.compactMap({ $0 as? RoutePointAnnotation }) {
                let annPt = map.convert(ann.coordinate, toPointTo: map)
                if abs(annPt.x - pt.x) < hitRadius && abs(annPt.y - pt.y) < hitRadius { return }
            }

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

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let poly = overlay as? SegmentPolyline {
                let r = MKPolylineRenderer(polyline: poly)
                r.strokeColor = NSColor.systemBlue
                r.lineWidth = 3
                r.lineCap = .round; r.lineJoin = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
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
        title = cue.name.isEmpty ? cue.pointType : cue.name
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
