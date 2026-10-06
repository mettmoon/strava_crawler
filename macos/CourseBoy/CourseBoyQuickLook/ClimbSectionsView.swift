import CoursePreviewCore
import MapKit
import SwiftUI

extension EnvironmentValues {
    /// 구간 행의 상세 버튼이 부르는 동작. 뷰어가 시트로 띄운다.
    @Entry var showClimbSectionDetail: ((CourseClimbSection) -> Void)? = nil
}

/// 큐시트 탭의 구간 행. 행을 누르면 다른 큐처럼 선택되고, 오른쪽 버튼으로 구간 상세를 연다.
struct ClimbSectionRow: View {
    let section: CourseClimbSection
    /// 지도·그래프에서 구간의 시작 큐나 정상 큐를 선택했을 때 강조한다.
    var isSelected = false
    /// 큐시트에서 선택 지점(또는 선택한 큐)을 기준으로 한 구간 시작점의 거리·상승.
    var selectionOffset: CueSheetSelectionOffset? = nil
    @Environment(\.showClimbSectionDetail) private var showDetail

    private var glyph: CuePointGlyph {
        sectionGlyph(for: section)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CueGlyphView(glyph: glyph)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(section.name)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(formatRouteDistance(section.startKm))
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text(section.category.label)
                        .fontWeight(.semibold)
                    Text(formatRouteDistance(section.lengthKm))
                    Text(formatElevationGain(section.elevationGain))
                    Text(formatGrade(section.averageGrade))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)

                if let summit = section.summitCue {
                    SectionEndCueLabel(cue: summit)
                        .font(.caption)
                        .lineLimit(1)
                }

                if let selectionOffset {
                    CueSheetSelectionOffsetText(offset: selectionOffset)
                        .font(.caption)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }

            Button {
                showDetail?(section)
            } label: {
                detailIcon
            }
            .buttonStyle(.plain)
            .accessibilityLabel("구간 상세")
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
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var detailIcon: some View {
        Image(systemName: "info.circle")
            .font(.title3)
            .foregroundStyle(glyph.color)
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
    }
}

// MARK: - Detail

struct ClimbSectionDetailView: View {
    let course: LoadedCourse
    let section: CourseClimbSection
    /// 큐를 선택하고 지도 탭으로 옮긴다. 상세 화면은 닫는다.
    var onShowCueOnMap: (CourseCuePoint) -> Void

    private let profile: ClimbProfile

    init(course: LoadedCourse, section: CourseClimbSection, onShowCueOnMap: @escaping (CourseCuePoint) -> Void) {
        self.course = course
        self.section = section
        self.onShowCueOnMap = onShowCueOnMap
        profile = ClimbProfile(trackPoints: course.trackPoints, section: section)
    }

    @Environment(\.dismiss) private var dismiss
    /// 고도 그래프에서 고른 지점. 구간 시작부터의 거리(km).
    @State private var selectedOffsetKm: Double?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 150), spacing: 8)]
    }

    /// 구간 시작 큐와 구간 안에 있는 큐. 매칭된 정상 큐도 위치 확인용으로 함께 보여준다.
    private var cuesInSection: [CourseCuePoint] {
        course.sortedCuePoints.filter {
            $0.id == section.startCue.id
                || section.contains(distanceKm: $0.distanceKm)
                || $0.id == section.summitCue?.id
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ClimbSectionMapView(profile: profile, selectedOffsetKm: selectedOffsetKm)
                    .frame(height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                header

                ClimbProfileChartView(
                    profile: profile,
                    summitOffsetKm: section.summitCue.map { $0.distanceKm - section.startKm },
                    selectedOffsetKm: $selectedOffsetKm
                )
                    .padding(12)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))

                LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                    MetricTile(title: "길이", value: formatRouteDistance(section.lengthKm), systemImage: "ruler")
                    MetricTile(
                        title: "고도차",
                        value: formatElevationGain(section.elevationGain),
                        systemImage: section.isDownhill ? "arrow.down.right" : "arrow.up.right"
                    )
                    MetricTile(title: "평균 경사", value: formatGrade(section.averageGrade), systemImage: "angle")
                    MetricTile(title: "최대 경사", value: formatGrade(section.maxGrade), systemImage: "exclamationmark.triangle")
                }

                ViewerSection(title: "상세 정보", systemImage: "info.circle") {
                    VStack(spacing: 0) {
                        DetailRow(
                            title: "등급",
                            value: section.isDownhill ? section.category.label : cuePointLabel(for: section.startCue.pointType)
                        )
                        DetailRow(title: "시작 위치", value: formatRouteDistance(section.startKm))
                        DetailRow(title: "종료 위치", value: formatRouteDistance(section.endKm))
                        DetailRow(title: "시작 고도", value: formatRouteElevation(section.startElevation))
                        DetailRow(title: section.isDownhill ? "종료 고도" : "정상 고도", value: formatRouteElevation(section.endElevation))
                        DetailRow(title: "누적 상승", value: formatRouteElevation(section.ascent))
                        DetailRow(title: "누적 하강", value: formatRouteElevation(section.descent))
                        DetailRow(title: section.isDownhill ? "종료 큐" : "정상 큐", value: summitDescription)
                        DetailRow(title: "종료 후 남은 거리", value: formatRouteDistance(max(0, course.totalDistanceKm - section.endKm)))
                    }
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                }

                if !section.startCue.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ViewerSection(title: "메모", systemImage: "note.text") {
                        Text(section.startCue.notes)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                if !cuesInSection.isEmpty {
                    ViewerSection(title: "구간 내 큐시트", systemImage: "list.bullet.rectangle") {
                        VStack(spacing: 0) {
                            ForEach(cuesInSection) { cue in
                                Button {
                                    dismiss()
                                    onShowCueOnMap(cue)
                                } label: {
                                    SectionCueRow(cue: cue, offsetKm: cue.distanceKm - section.startKm)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(section.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(spacing: 12) {
            CueGlyphView(glyph: sectionGlyph(for: section))
            VStack(alignment: .leading, spacing: 3) {
                Text(section.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text("\(formatRouteDistance(section.startKm)) → \(formatRouteDistance(section.endKm))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let summit = section.summitCue {
                    SectionEndCueLabel(cue: summit)
                        .font(.subheadline)
                        .lineLimit(2)
                }
            }
        }
    }

    private var summitDescription: String {
        guard let summit = section.summitCue else { return "-" }
        return "\(summit.displayName) (\(formatRouteDistance(summit.distanceKm)))"
    }
}

private struct SectionCueRow: View {
    let cue: CourseCuePoint
    let offsetKm: Double

    var body: some View {
        HStack(spacing: 10) {
            CueGlyphView(glyph: cuePointGlyph(for: cue.pointType))
                .scaleEffect(0.8)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(cue.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(cuePointLabel(for: cue.pointType))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(offsetKm >= 0 ? "+\(formatRouteDistance(offsetKm))" : "-\(formatRouteDistance(-offsetKm))")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 50)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Map

/// 구간 경로를 200m 조각마다 경사 색으로 칠한 지도. 이동·확대·회전할 수 있고 버튼으로 구간 전체 보기로 돌아온다.
private struct ClimbSectionMapView: View {
    let profile: ClimbProfile
    var selectedOffsetKm: Double?

    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position, interactionModes: [.pan, .zoom, .rotate]) {
            // 색 조각이 배경 지도와 섞이지 않게 흰 테두리를 먼저 깐다.
            MapPolyline(coordinates: profile.samples.map(\.coordinate))
                .stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))

            ForEach(profile.buckets.indices, id: \.self) { index in
                let bucket = profile.buckets[index]
                MapPolyline(coordinates: bucket.points.map(\.coordinate))
                    .stroke(
                        GradeBand(grade: bucket.grade).color,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                    )
            }

            if let start = profile.samples.first {
                Annotation("시작", coordinate: start.coordinate, anchor: .center) {
                    Circle()
                        .fill(.white)
                        .frame(width: 12, height: 12)
                        .overlay { Circle().strokeBorder(.black, lineWidth: 2.5) }
                }
                .annotationTitles(.hidden)
            }
            if let end = profile.samples.last {
                Annotation("정상", coordinate: end.coordinate, anchor: .center) {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(.black, in: Circle())
                        .overlay { Circle().strokeBorder(.white, lineWidth: 1.5) }
                }
                .annotationTitles(.hidden)
            }

            if let selectedOffsetKm {
                Annotation("선택 지점", coordinate: profile.sample(atKm: selectedOffsetKm).coordinate, anchor: .center) {
                    Circle()
                        .fill(.cyan)
                        .frame(width: 14, height: 14)
                        .overlay { Circle().strokeBorder(.white, lineWidth: 2.5) }
                        .shadow(color: .black.opacity(0.3), radius: 2)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .accessibilityLabel("구간 지도")
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    position = fittedPosition
                }
            } label: {
                Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
                    .background(.regularMaterial, in: Circle())
                    .overlay { Circle().strokeBorder(Color(.separator), lineWidth: 0.5) }
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityLabel("구간 전체 보기")
        }
        .onAppear {
            position = fittedPosition
        }
    }

    private var fittedPosition: MapCameraPosition {
        let points = profile.samples.map { MKMapPoint($0.coordinate) }
        guard let first = points.first else { return .automatic }
        var rect = MKMapRect(origin: first, size: MKMapSize(width: 0, height: 0))
        for point in points.dropFirst() {
            rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 0, height: 0)))
        }
        let padding = max(rect.width, rect.height) * 0.2 + 200
        return .rect(rect.insetBy(dx: -padding, dy: -padding))
    }
}

// MARK: - Chart

/// 구간 고도 그래프. 200m 조각마다 평균 경사를 색으로 칠한다.
/// 누르거나 가로로 끌면 그 지점의 거리·고도·경사를 보여준다.
private struct ClimbProfileChartView: View {
    let profile: ClimbProfile
    let summitOffsetKm: Double?
    @Binding var selectedOffsetKm: Double?

    @State private var scrubFeedbackTrigger = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if profile.samples.count >= 2 {
                Canvas { context, size in
                    draw(size: size, context: context)
                }
                .frame(height: Layout.height)
                .overlay {
                    GeometryReader { proxy in
                        let rect = plotRect(in: proxy.size)
                        // 세로 스크롤과 겹치지 않게 UIKit 인식기로 탭과 가로 끌기만 받는다.
                        ProfileScrubGestureView(
                            onTap: { x in select(atX: x, rect: rect) },
                            onDrag: { state, x in
                                if state == .began { scrubFeedbackTrigger += 1 }
                                select(atX: x, rect: rect)
                            }
                        )
                    }
                }
                .sensoryFeedback(.impact(weight: .medium), trigger: scrubFeedbackTrigger)
                .accessibilityElement()
                .accessibilityLabel("구간 고도 그래프")
                .accessibilityValue(profile.accessibilitySummary)
                .accessibilityHint("누르거나 가로로 끌면 해당 지점의 거리와 경사를 보여주고 지도에 표시합니다.")
            } else {
                Text("고도 데이터 없음")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Layout.height)
            }
        }
    }

    private func plotRect(in size: CGSize) -> CGRect {
        CGRect(
            x: Layout.leftPad,
            y: Layout.topPad,
            width: max(1, size.width - Layout.leftPad - Layout.rightPad),
            height: max(1, size.height - Layout.topPad - Layout.bottomPad)
        )
    }

    private func select(atX x: CGFloat, rect: CGRect) {
        let ratio = min(max((x - rect.minX) / rect.width, 0), 1)
        selectedOffsetKm = Double(ratio) * profile.lengthKm
    }

    private func draw(size: CGSize, context: GraphicsContext) {
        let rect = plotRect(in: size)
        let length = max(profile.lengthKm, 0.001)
        let eleSpan = max(profile.maxEle - profile.minEle, 1)

        func x(_ offsetKm: Double) -> CGFloat {
            rect.minX + CGFloat(offsetKm / length) * rect.width
        }
        func y(_ ele: Double) -> CGFloat {
            rect.maxY - CGFloat((ele - profile.minEle) / eleSpan) * rect.height
        }

        drawGrid(rect: rect, context: context, x: x, y: y)

        // 같은 색끼리 모아 한 번에 채운다.
        var bandPaths = [GradeBand: Path]()
        for bucket in profile.buckets {
            guard let first = bucket.points.first, let last = bucket.points.last else { continue }
            var area = Path()
            area.move(to: CGPoint(x: x(first.offsetKm), y: rect.maxY))
            for point in bucket.points {
                area.addLine(to: CGPoint(x: x(point.offsetKm), y: y(point.ele)))
            }
            area.addLine(to: CGPoint(x: x(last.offsetKm), y: rect.maxY))
            area.closeSubpath()
            bandPaths[GradeBand(grade: bucket.grade), default: Path()].addPath(area)
        }
        for (band, path) in bandPaths {
            context.fill(path, with: .color(band.color.opacity(0.85)))
        }

        var line = Path()
        for (index, sample) in profile.samples.enumerated() {
            let point = CGPoint(x: x(sample.offsetKm), y: y(sample.ele))
            if index == 0 { line.move(to: point) } else { line.addLine(to: point) }
        }
        context.stroke(line, with: .color(.primary.opacity(0.6)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))

        drawSummit(rect: rect, context: context, x: x, y: y)

        if let selectedOffsetKm {
            drawSelection(at: selectedOffsetKm, rect: rect, context: context, x: x, y: y)
        }
    }

    /// 지도 탭 고도 그래프와 같은 모양으로 선택 지점과 거리·고도·경사 말풍선을 그린다.
    private func drawSelection(
        at offsetKm: Double,
        rect: CGRect,
        context: GraphicsContext,
        x: (Double) -> CGFloat,
        y: (Double) -> CGFloat
    ) {
        let sample = profile.sample(atKm: offsetKm)
        let pointX = x(offsetKm)
        let pointY = y(sample.ele)

        var guide = Path()
        guide.move(to: CGPoint(x: pointX, y: rect.minY))
        guide.addLine(to: CGPoint(x: pointX, y: rect.maxY))
        context.stroke(guide, with: .color(.cyan), lineWidth: 1.5)

        let dot = CGRect(x: pointX - 4.5, y: pointY - 4.5, width: 9, height: 9)
        context.fill(Path(ellipseIn: dot), with: .color(.cyan))
        context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 1.5)

        let grade = String(format: "%+.1f%%", profile.grade(atKm: offsetKm))
        let label = context.resolve(
            Text("\(formatRouteDistance(offsetKm)) · \(formatRouteElevation(sample.ele)) · \(grade)")
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        )
        let textSize = label.measure(in: CGSize(width: 300, height: 30))
        let bubbleSize = CGSize(width: textSize.width + 12, height: textSize.height + 6)
        var origin = CGPoint(x: pointX - bubbleSize.width / 2, y: rect.minY + 3)
        origin.x = min(max(origin.x, rect.minX + 2), rect.maxX - bubbleSize.width - 2)
        // 점과 겹치면 아래쪽으로 내린다.
        if pointY < origin.y + bubbleSize.height + 6 {
            origin.y = min(rect.maxY - bubbleSize.height - 3, pointY + 8)
        }
        let bubble = Path(roundedRect: CGRect(origin: origin, size: bubbleSize), cornerRadius: 5)
        context.fill(bubble, with: .color(Color(.systemBackground).opacity(0.92)))
        context.stroke(bubble, with: .color(Color.cyan.opacity(0.7)), lineWidth: 0.8)
        context.draw(
            label,
            at: CGPoint(x: origin.x + bubbleSize.width / 2, y: origin.y + bubbleSize.height / 2),
            anchor: .center
        )
    }

    private func drawGrid(
        rect: CGRect,
        context: GraphicsContext,
        x: (Double) -> CGFloat,
        y: (Double) -> CGFloat
    ) {
        let gridColor = Color.secondary.opacity(0.18)
        let eleStep = MapElevationChartView.niceStep(
            span: profile.maxEle - profile.minEle,
            availableLength: rect.height,
            targetSpacing: 36
        )
        var ele = (profile.minEle / eleStep).rounded(.up) * eleStep
        while ele <= profile.maxEle + 0.001 {
            let lineY = y(ele)
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: lineY))
            path.addLine(to: CGPoint(x: rect.maxX, y: lineY))
            context.stroke(path, with: .color(gridColor), lineWidth: 0.5)
            context.draw(
                Text("\(Int(ele))").font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary),
                at: CGPoint(x: rect.minX - 4, y: lineY),
                anchor: .trailing
            )
            ele += eleStep
        }

        let kmStep = MapElevationChartView.niceStep(span: profile.lengthKm, availableLength: rect.width, targetSpacing: 48)
        var km = 0.0
        while km <= profile.lengthKm + kmStep * 0.001 {
            context.draw(
                Text(formatKm(km)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary),
                at: CGPoint(x: x(km), y: rect.maxY + 3),
                anchor: .top
            )
            km += kmStep
        }

        var baseline = Path()
        baseline.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        baseline.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        context.stroke(baseline, with: .color(.secondary.opacity(0.35)), lineWidth: 0.5)
    }

    /// 오르막 끝(정상) 표시. 매칭된 정상 큐가 있으면 그 위치에도 가이드 선을 긋는다.
    private func drawSummit(
        rect: CGRect,
        context: GraphicsContext,
        x: (Double) -> CGFloat,
        y: (Double) -> CGFloat
    ) {
        if let offset = summitOffsetKm, offset >= 0, offset <= profile.lengthKm {
            var guide = Path()
            guide.move(to: CGPoint(x: x(offset), y: rect.minY))
            guide.addLine(to: CGPoint(x: x(offset), y: rect.maxY))
            context.stroke(guide, with: .color(.green.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }

        guard let last = profile.samples.last else { return }
        let peak = CGPoint(x: x(last.offsetKm), y: y(last.ele))
        let dot = CGRect(x: peak.x - 4.5, y: peak.y - 4.5, width: 9, height: 9)
        context.fill(Path(ellipseIn: dot), with: .color(.green))
        context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 1.5)
    }

    private func formatKm(_ km: Double) -> String {
        let hundredths = (km * 100).rounded()
        if hundredths.truncatingRemainder(dividingBy: 100) == 0 { return String(format: "%.0f", km) }
        if hundredths.truncatingRemainder(dividingBy: 10) == 0 { return String(format: "%.1f", km) }
        return String(format: "%.2f", km)
    }

    private enum Layout {
        static let height: CGFloat = 200
        static let leftPad: CGFloat = 32
        static let rightPad: CGFloat = 6
        static let topPad: CGFloat = 16
        static let bottomPad: CGFloat = 16
    }
}

/// 탭과 가로 끌기만 받는 제스처 뷰. 세로로 끌면 바깥 스크롤 뷰가 받는다.
private struct ProfileScrubGestureView: UIViewRepresentable {
    var onTap: (CGFloat) -> Void
    var onDrag: (UIGestureRecognizer.State, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let coordinator = context.coordinator
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.delegate = coordinator
        [tap, pan].forEach(view.addGestureRecognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: ProfileScrubGestureView

        init(parent: ProfileScrubGestureView) {
            self.parent = parent
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onTap(recognizer.location(in: recognizer.view).x)
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            parent.onDrag(recognizer.state, recognizer.location(in: recognizer.view).x)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }
    }
}

// MARK: - Profile data

/// 구간의 고도 샘플과 200m 조각별 평균 경사. 지도와 고도 그래프가 같은 조각을 쓴다.
private struct ClimbProfile {
    struct Sample {
        var offsetKm: Double
        var ele: Double
        var coordinate: CLLocationCoordinate2D
    }

    struct Bucket {
        /// 조각 경계를 보간한 시작·끝 샘플과 그 사이 트랙 포인트.
        var points: [Sample]
        /// 퍼센트 단위.
        var grade: Double
    }

    static let bucketKm = 0.2

    let samples: [Sample]
    let buckets: [Bucket]
    let lengthKm: Double
    let minEle: Double
    let maxEle: Double

    init(trackPoints: [TrackPoint], section: CourseClimbSection) {
        let startKm = section.startKm
        let range = section.startIndex...min(section.endIndex, trackPoints.count - 1)
        let samples = trackPoints[range].compactMap { point in
            point.ele.map { Sample(offsetKm: point.cumKm - startKm, ele: $0, coordinate: point.coordinate) }
        }
        self.samples = samples
        lengthKm = section.lengthKm

        var buckets: [Bucket] = []
        if samples.count >= 2 {
            var cursor = 0
            var start = 0.0
            while start < lengthKm - 0.000_1 {
                // 마지막 조각이 너무 짧으면 앞 칸에 붙인다.
                var end = min(start + Self.bucketKm, lengthKm)
                if lengthKm - end < Self.bucketKm * 0.3 { end = lengthKm }

                var points = [Self.sample(at: start, in: samples)]
                while cursor < samples.count, samples[cursor].offsetKm <= start { cursor += 1 }
                while cursor < samples.count, samples[cursor].offsetKm < end {
                    points.append(samples[cursor])
                    cursor += 1
                }
                let last = Self.sample(at: end, in: samples)
                points.append(last)

                let meters = (end - start) * 1_000
                let grade = meters > 1 ? (last.ele - points[0].ele) / meters * 100 : 0
                buckets.append(Bucket(points: points, grade: grade))
                start = end
            }
        }
        self.buckets = buckets

        let elevations = samples.map(\.ele)
        let low = elevations.min() ?? 0
        let high = elevations.max() ?? 100
        let pad = max((high - low) * 0.12, 10)
        minEle = max(0, ((low - pad) / 10).rounded(.down) * 10)
        maxEle = ((high + pad) / 10).rounded(.up) * 10
    }

    /// 구간 시작부터 km 지점의 보간 샘플.
    func sample(atKm km: Double) -> Sample {
        Self.sample(at: km, in: samples)
    }

    /// km 지점이 속한 200m 조각의 평균 경사. 그래프 색과 같은 값이다.
    func grade(atKm km: Double) -> Double {
        let index = min(max(Int(km / Self.bucketKm), 0), buckets.count - 1)
        guard buckets.indices.contains(index) else { return 0 }
        return buckets[index].grade
    }

    var accessibilitySummary: String {
        guard let steepest = buckets.map(\.grade).max() else { return "" }
        return String(format: "200 m 단위 최대 경사 %.1f%%", steepest)
    }

    /// 거리 위치의 고도와 좌표를 앞뒤 샘플 사이에서 선형 보간한다.
    private static func sample(at km: Double, in samples: [Sample]) -> Sample {
        guard let first = samples.first, let last = samples.last else {
            return Sample(offsetKm: km, ele: 0, coordinate: CLLocationCoordinate2D())
        }
        if km <= first.offsetKm { return first }
        if km >= last.offsetKm { return last }
        var low = 0
        var high = samples.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if samples[mid].offsetKm < km { low = mid } else { high = mid }
        }
        let a = samples[low]
        let b = samples[high]
        let span = b.offsetKm - a.offsetKm
        let t = span > 0 ? (km - a.offsetKm) / span : 0
        return Sample(
            offsetKm: km,
            ele: a.ele + (b.ele - a.ele) * t,
            coordinate: CLLocationCoordinate2D(
                latitude: a.coordinate.latitude + (b.coordinate.latitude - a.coordinate.latitude) * t,
                longitude: a.coordinate.longitude + (b.coordinate.longitude - a.coordinate.longitude) * t
            )
        )
    }
}

// MARK: - Formatting

/// 다운힐의 시작 큐는 Straight라 큐 아이콘 대신 내리막 아이콘을 쓴다.
private func sectionGlyph(for section: CourseClimbSection) -> CuePointGlyph {
    guard section.isDownhill else { return cuePointGlyph(for: section.startCue.pointType) }
    return CuePointGlyph(symbol: "arrow.down.right", text: nil, color: .teal, uiColor: .systemTeal)
}

/// 구간 끝 큐(정상·Valley)를 그 큐의 아이콘과 색으로 보여준다.
private struct SectionEndCueLabel: View {
    let cue: CourseCuePoint

    var body: some View {
        let glyph = cuePointGlyph(for: cue.pointType)
        Label(cue.displayName, systemImage: glyph.symbol ?? "flag.checkered")
            .foregroundStyle(glyph.color)
    }
}

private func formatGrade(_ grade: Double?) -> String {
    guard let grade else { return "-" }
    return String(format: "%.1f%%", grade)
}

private func formatElevationGain(_ meters: Double?) -> String {
    guard let meters else { return "-" }
    return String(format: "%+.0f m", meters)
}
