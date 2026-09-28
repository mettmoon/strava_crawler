import CoursePreviewCore
import SwiftUI
import UIKit

/// 지도 탭 하단에 붙는 가로형 고도 그래프.
/// 경사도 구간별 색상, 큐시트 표시, 핀치 줌/드래그 이동, 탭 선택을 지원한다.
struct MapElevationChartView: View {
    let course: LoadedCourse
    @Binding var selectedCueID: UUID?
    @Binding var selectedProfilePoint: CourseProfileSelection?
    var currentLocation: CourseProfileSelection? = nil
    /// 길게 눌러 위치를 조정하기 시작하거나 끝낼 때 호출된다.
    var onScrubbingChanged: (Bool) -> Void = { _ in }

    @State private var profile: MapElevationProfile?
    @State private var profileCourseID: UUID?
    /// 1이면 코스 전체, 값이 클수록 확대.
    @State private var zoom: CGFloat = 1
    @State private var visibleStartKm: Double = 0
    @State private var pinchBase: (zoom: CGFloat, startKm: Double)?
    @State private var panBaseStartKm: Double?
    @State private var scrubFeedbackTrigger = 0
    @State private var cueSnapFeedbackTrigger = 0

    private var cues: [CourseCuePoint] {
        course.sortedCuePoints
    }

    private var selectedCue: CourseCuePoint? {
        guard let selectedCueID else { return nil }
        return course.cuePoints.first { $0.id == selectedCueID }
    }

    var body: some View {
        VStack(spacing: 6) {
            header
            if let profile, profile.samples.count >= 2 {
                GeometryReader { proxy in
                    chart(profile: profile, size: proxy.size)
                }
                .frame(height: Layout.chartHeight)
            } else {
                Text("고도 데이터 없음")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: Layout.chartHeight)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Color(.systemBackground))
        .overlay(alignment: .top) {
            Divider()
        }
        .onAppear(perform: loadProfileIfNeeded)
        .onChange(of: course.id) { _, _ in loadProfileIfNeeded() }
        .onChange(of: focusedDistanceKm) { _, km in
            guard let km else { return }
            revealIfNeeded(km)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                ForEach(GradeBand.allCases, id: \.self) { band in
                    HStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(band.color)
                            .frame(width: 8, height: 8)
                        Text(band.legendLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("경사도 범례")

            Spacer(minLength: 4)

            if zoom > 1.01 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        zoom = 1
                        visibleStartKm = 0
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(String(format: "×%.1f", zoom))
                            .monospacedDigit()
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                    }
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(.secondarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("고도 그래프 전체 보기")
            }
        }
        .frame(height: 18)
    }

    // MARK: - Chart

    private func chart(profile: MapElevationProfile, size: CGSize) -> some View {
        let rect = chartRect(in: size)
        let window = visibleWindow(profile: profile)

        return Canvas { context, _ in
            draw(profile: profile, window: window, rect: rect, context: context)
        }
        .overlay {
            // 제스처는 UIKit 인식기로 처리한다. SwiftUI의 LongPressGesture와 DragGesture를
            // 동시에 붙이면 실제 기기에서 길게 누르기가 인식되지 않는 경우가 있었다.
            ChartGestureView(
                onTap: { location in
                    handleTap(at: location, profile: profile, window: window, rect: rect)
                },
                onLongPress: { state, location in
                    handleLongPress(state, at: location, profile: profile, window: window, rect: rect)
                },
                onPan: { state, translationX in
                    handlePan(state, translationX: translationX, profile: profile, rect: rect)
                },
                onPinch: { state, scale, anchorX in
                    handlePinch(state, scale: scale, anchorX: anchorX, profile: profile, rect: rect)
                }
            )
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: scrubFeedbackTrigger)
        .sensoryFeedback(.selection, trigger: cueSnapFeedbackTrigger)
        .accessibilityElement()
        .accessibilityLabel("고도 그래프")
        .accessibilityHint("누르면 지도에서 해당 지점으로 이동합니다. 길게 누른 채 움직이면 위치를 조정하고, 두 손가락으로 확대할 수 있습니다.")
    }

    private func draw(
        profile: MapElevationProfile,
        window: ClosedRange<Double>,
        rect: CGRect,
        context: GraphicsContext
    ) {
        let span = max(window.upperBound - window.lowerBound, 0.0001)
        let eleSpan = max(profile.maxEle - profile.minEle, 1)

        func x(_ km: Double) -> CGFloat {
            rect.minX + CGFloat((km - window.lowerBound) / span) * rect.width
        }
        func y(_ ele: Double) -> CGFloat {
            rect.maxY - CGFloat((ele - profile.minEle) / eleSpan) * rect.height
        }

        drawGrid(profile: profile, window: window, rect: rect, context: context, x: x, y: y)

        var clipped = context
        clipped.clip(to: Path(rect))

        // 보이는 구간만, 화면 Layout.minimumSegmentWidth 미만 간격의 포인트는 건너뛰며 그린다.
        let samples = profile.samples
        let first = max(0, profile.lowerBound(km: window.lowerBound) - 1)
        let last = min(samples.count - 1, profile.lowerBound(km: window.upperBound) + 1)
        guard last > first else { return }

        var bandPaths = [GradeBand: Path]()
        var line = Path()
        var previousSample = samples[first]
        var previous = CGPoint(x: x(previousSample.km), y: y(previousSample.ele))
        line.move(to: previous)
        for index in (first + 1)...last {
            let sample = samples[index]
            let point = CGPoint(x: x(sample.km), y: y(sample.ele))
            guard point.x - previous.x >= Layout.minimumSegmentWidth || index == last else { continue }
            // 축소해서 여러 포인트를 한 구간으로 합칠 때는 그 구간의 평균 경사로 칠한다.
            let band = GradeBand(grade: profile.grade(from: previousSample, to: sample))
            var quad = Path()
            quad.move(to: CGPoint(x: previous.x, y: rect.maxY))
            quad.addLine(to: previous)
            quad.addLine(to: point)
            quad.addLine(to: CGPoint(x: point.x, y: rect.maxY))
            quad.closeSubpath()
            bandPaths[band, default: Path()].addPath(quad)
            line.addLine(to: point)
            previous = point
            previousSample = sample
        }

        for (band, path) in bandPaths {
            clipped.fill(path, with: .color(band.color.opacity(0.85)))
        }
        clipped.stroke(
            line,
            with: .color(.primary.opacity(0.55)),
            style: StrokeStyle(lineWidth: 1, lineJoin: .round)
        )

        drawCues(window: window, rect: rect, context: context, x: x)

        if let currentLocation, window.contains(currentLocation.distanceKm) {
            drawCurrentLocation(currentLocation, profile: profile, rect: rect, context: context, x: x, y: y)
        }

        if let selection = displayedSelection, window.contains(selection.distanceKm) {
            drawSelection(selection, profile: profile, rect: rect, context: context, x: x, y: y)
        }
    }

    private func drawGrid(
        profile: MapElevationProfile,
        window: ClosedRange<Double>,
        rect: CGRect,
        context: GraphicsContext,
        x: (Double) -> CGFloat,
        y: (Double) -> CGFloat
    ) {
        let gridColor = Color.secondary.opacity(0.18)

        let eleStep = ElevationProfileView.niceStep(
            span: profile.maxEle - profile.minEle,
            availableLength: rect.height,
            targetSpacing: 32
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

        let span = window.upperBound - window.lowerBound
        let kmStep = ElevationProfileView.niceStep(span: span, availableLength: rect.width, targetSpacing: 56)
        var km = (window.lowerBound / kmStep).rounded(.up) * kmStep
        while km <= window.upperBound + kmStep * 0.001 {
            let lineX = x(km)
            var path = Path()
            path.move(to: CGPoint(x: lineX, y: rect.minY))
            path.addLine(to: CGPoint(x: lineX, y: rect.maxY))
            context.stroke(path, with: .color(gridColor.opacity(0.6)), lineWidth: 0.5)
            context.draw(
                Text(formatKmTick(km, step: kmStep)).font(.system(size: 9).monospacedDigit()).foregroundStyle(.secondary),
                at: CGPoint(x: lineX, y: rect.maxY + 3),
                anchor: .top
            )
            km += kmStep
        }

        context.stroke(Path(rect), with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
    }

    private func drawCues(
        window: ClosedRange<Double>,
        rect: CGRect,
        context: GraphicsContext,
        x: (Double) -> CGFloat
    ) {
        let visible = cues.filter { window.contains($0.distanceKm) }
        for cue in visible where cue.id != selectedCueID {
            let glyph = cuePointGlyph(for: cue.pointType)
            let cueX = x(cue.distanceKm)
            var guide = Path()
            guide.move(to: CGPoint(x: cueX, y: rect.minY))
            guide.addLine(to: CGPoint(x: cueX, y: rect.maxY))
            context.stroke(
                guide,
                with: .color(glyph.color.opacity(0.4)),
                style: StrokeStyle(lineWidth: 0.8, dash: [3, 2])
            )
        }

        for icon in cueIcons(window: window, rect: rect) {
            let cue = icon.cue
            let selected = cue.id == selectedCueID
            let glyph = cuePointGlyph(for: cue.pointType)
            let cueX = icon.x

            if selected {
                var guide = Path()
                guide.move(to: CGPoint(x: cueX, y: rect.minY))
                guide.addLine(to: CGPoint(x: cueX, y: rect.maxY))
                context.stroke(guide, with: .color(glyph.color), lineWidth: 1.5)
            }

            let radius: CGFloat = selected ? Layout.cueIconRadius + 2 : Layout.cueIconRadius
            let center = CGPoint(x: cueX, y: Layout.cueBandHeight / 2)
            let circle = Path(ellipseIn: CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            ))
            context.fill(circle, with: .color(glyph.color))
            context.stroke(circle, with: .color(.white), lineWidth: selected ? 1.5 : 1)

            if let symbol = glyph.symbol {
                var image = context.resolve(Image(systemName: symbol))
                image.shading = .color(.white)
                let side = radius * 1.1
                let imageSize = image.size
                let scale = side / max(imageSize.width, imageSize.height, 1)
                let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                context.draw(
                    image,
                    in: CGRect(
                        x: center.x - drawSize.width / 2,
                        y: center.y - drawSize.height / 2,
                        width: drawSize.width,
                        height: drawSize.height
                    )
                )
            } else if let text = glyph.text {
                context.draw(
                    Text(text).font(.system(size: radius * 0.95, weight: .bold)).foregroundStyle(.white),
                    at: center,
                    anchor: .center
                )
            }
        }
    }

    private func drawSelection(
        _ selection: CourseProfileSelection,
        profile: MapElevationProfile,
        rect: CGRect,
        context: GraphicsContext,
        x: (Double) -> CGFloat,
        y: (Double) -> CGFloat
    ) {
        let color = selectedCue.map { cuePointGlyph(for: $0.pointType).color } ?? .cyan
        let pointX = x(selection.distanceKm)
        let elevation = selection.elevationMeters ?? profile.sample(nearestKm: selection.distanceKm).ele
        let pointY = y(elevation)

        if selectedCue == nil {
            var guide = Path()
            guide.move(to: CGPoint(x: pointX, y: rect.minY))
            guide.addLine(to: CGPoint(x: pointX, y: rect.maxY))
            context.stroke(guide, with: .color(color), lineWidth: 1.5)
        }

        let dot = CGRect(x: pointX - 4.5, y: pointY - 4.5, width: 9, height: 9)
        context.fill(Path(ellipseIn: dot), with: .color(color))
        context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 1.5)

        let grade = profile.sample(nearestKm: selection.distanceKm).grade
        let label = context.resolve(
            Text("\(formatRouteDistance(selection.distanceKm)) · \(formatRouteElevation(elevation)) · \(formatGrade(grade))")
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
        context.stroke(bubble, with: .color(color.opacity(0.7)), lineWidth: 0.8)
        context.draw(
            label,
            at: CGPoint(x: origin.x + bubbleSize.width / 2, y: origin.y + bubbleSize.height / 2),
            anchor: .center
        )
    }

    private func drawCurrentLocation(
        _ location: CourseProfileSelection,
        profile: MapElevationProfile,
        rect: CGRect,
        context: GraphicsContext,
        x: (Double) -> CGFloat,
        y: (Double) -> CGFloat
    ) {
        let pointX = x(location.distanceKm)
        let elevation = location.elevationMeters ?? profile.sample(nearestKm: location.distanceKm).ele
        let pointY = y(elevation)

        var guide = Path()
        guide.move(to: CGPoint(x: pointX, y: rect.minY))
        guide.addLine(to: CGPoint(x: pointX, y: rect.maxY))
        context.stroke(guide, with: .color(.blue.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))

        let halo = CGRect(x: pointX - 9, y: pointY - 9, width: 18, height: 18)
        context.fill(Path(ellipseIn: halo), with: .color(.blue.opacity(0.2)))
        let dot = CGRect(x: pointX - 5, y: pointY - 5, width: 10, height: 10)
        context.fill(Path(ellipseIn: dot), with: .color(.blue))
        context.stroke(Path(ellipseIn: dot), with: .color(.white), lineWidth: 2)
    }

    // MARK: - Interaction

    private func handleTap(
        at location: CGPoint,
        profile: MapElevationProfile,
        window: ClosedRange<Double>,
        rect: CGRect
    ) {
        if location.y <= Layout.cueBandHeight + 4 {
            let hit = cueIcons(window: window, rect: rect)
                .map { (cue: $0.cue, dx: abs($0.x - location.x)) }
                .filter { $0.dx <= Layout.cueIconRadius + 6 }
                .min { $0.dx < $1.dx }
            if let hit {
                if selectedCueID == hit.cue.id {
                    selectedCueID = nil
                } else {
                    selectedCueID = hit.cue.id
                }
                return
            }
        }

        if let cue = magnetCue(atX: location.x, window: window, rect: rect, holding: nil) {
            selectCue(cue)
            return
        }
        selectProfilePoint(atX: location.x, profile: profile, window: window, rect: rect)
    }

    /// 길게 눌러 조정하는 중의 선택. 큐 가이드 라인 근처에서는 큐에 달라붙는다.
    private func scrub(
        atX x: CGFloat,
        profile: MapElevationProfile,
        window: ClosedRange<Double>,
        rect: CGRect
    ) {
        if let cue = magnetCue(atX: x, window: window, rect: rect, holding: selectedCueID) {
            if selectedCueID != cue.id {
                selectCue(cue)
                cueSnapFeedbackTrigger += 1
            }
            return
        }
        selectProfilePoint(atX: x, profile: profile, window: window, rect: rect)
    }

    /// x 근처에 아이콘이 그려진 큐가 있으면 반환한다.
    /// 이미 붙어 있는 큐(holding)는 더 넓은 범위까지 유지해서 경계에서 깜빡이지 않게 한다.
    private func magnetCue(
        atX x: CGFloat,
        window: ClosedRange<Double>,
        rect: CGRect,
        holding heldID: UUID?
    ) -> CourseCuePoint? {
        let icons = cueIcons(window: window, rect: rect)
        if let heldID,
           let held = icons.first(where: { $0.cue.id == heldID }),
           abs(held.x - x) <= Layout.cueMagnetReleaseDistance {
            return held.cue
        }
        return icons
            .map { (cue: $0.cue, dx: abs($0.x - x)) }
            .filter { $0.dx <= Layout.cueMagnetCaptureDistance }
            .min { $0.dx < $1.dx }?
            .cue
    }

    private func selectCue(_ cue: CourseCuePoint) {
        selectedProfilePoint = nil
        selectedCueID = cue.id
    }

    private func selectProfilePoint(
        atX x: CGFloat,
        profile: MapElevationProfile,
        window: ClosedRange<Double>,
        rect: CGRect
    ) {
        let span = max(window.upperBound - window.lowerBound, 0.0001)
        let ratio = Double(min(max((x - rect.minX) / rect.width, 0), 1))
        let km = window.lowerBound + ratio * span
        let sample = profile.sample(nearestKm: km)
        guard course.trackPoints.indices.contains(sample.trackIndex),
              selectedProfilePoint?.trackIndex != sample.trackIndex || selectedCueID != nil else { return }
        selectedCueID = nil
        selectedProfilePoint = CourseProfileSelection(
            trackIndex: sample.trackIndex,
            point: course.trackPoints[sample.trackIndex]
        )
    }

    private func handlePinch(
        _ state: UIGestureRecognizer.State,
        scale: CGFloat,
        anchorX: CGFloat,
        profile: MapElevationProfile,
        rect: CGRect
    ) {
        switch state {
        case .began:
            pinchBase = (zoom, visibleStartKm)
        case .changed:
            guard let base = pinchBase else { return }
            let total = profile.totalKm
            let baseSpan = total / Double(base.zoom)
            let anchorRatio = Double(min(max((anchorX - rect.minX) / rect.width, 0), 1))
            let anchorKm = base.startKm + anchorRatio * baseSpan

            let newZoom = min(max(base.zoom * scale, 1), maxZoom(for: profile))
            let newSpan = total / Double(newZoom)
            zoom = newZoom
            visibleStartKm = clampedStart(anchorKm - anchorRatio * newSpan, span: newSpan, total: total)
        default:
            pinchBase = nil
        }
    }

    /// 확대 상태에서 한 손가락으로 끌면 그래프를 좌우로 이동한다.
    private func handlePan(
        _ state: UIGestureRecognizer.State,
        translationX: CGFloat,
        profile: MapElevationProfile,
        rect: CGRect
    ) {
        switch state {
        case .began:
            panBaseStartKm = visibleStartKm
        case .changed:
            guard zoom > 1, let base = panBaseStartKm else { return }
            let span = profile.totalKm / Double(zoom)
            let deltaKm = Double(translationX / rect.width) * span
            visibleStartKm = clampedStart(base - deltaKm, span: span, total: profile.totalKm)
        default:
            panBaseStartKm = nil
        }
    }

    /// 제자리에서 scrubPressDuration 이상 누르면 위치를 선택하고, 이후 드래그로 미세 조정한다.
    private func handleLongPress(
        _ state: UIGestureRecognizer.State,
        at location: CGPoint,
        profile: MapElevationProfile,
        window: ClosedRange<Double>,
        rect: CGRect
    ) {
        switch state {
        case .began:
            scrubFeedbackTrigger += 1
            onScrubbingChanged(true)
            scrub(atX: location.x, profile: profile, window: window, rect: rect)
        case .changed:
            scrub(atX: location.x, profile: profile, window: window, rect: rect)
        default:
            onScrubbingChanged(false)
        }
    }

    /// 지도나 다른 탭에서 선택한 지점이 화면 밖이면 그 지점이 가운데 오도록 이동한다.
    private func revealIfNeeded(_ km: Double) {
        guard let profile, zoom > 1 else { return }
        let window = visibleWindow(profile: profile)
        guard !window.contains(km) else { return }
        let span = window.upperBound - window.lowerBound
        withAnimation(.easeInOut(duration: 0.2)) {
            visibleStartKm = clampedStart(km - span / 2, span: span, total: profile.totalKm)
        }
    }

    // MARK: - Helpers

    /// 아이콘을 그릴 큐 목록. 앞 아이콘과 겹치는 큐는 가이드 라인만 남기고 아이콘은 생략한다.
    /// 선택한 큐는 항상 그리고 맨 위에 오도록 마지막에 둔다.
    private func cueIcons(window: ClosedRange<Double>, rect: CGRect) -> [(cue: CourseCuePoint, x: CGFloat)] {
        let span = max(window.upperBound - window.lowerBound, 0.0001)
        let minimumGap = Layout.cueIconRadius * 2 + 1
        var icons: [(cue: CourseCuePoint, x: CGFloat)] = []
        var selected: (cue: CourseCuePoint, x: CGFloat)?
        var lastX = -CGFloat.infinity
        for cue in cues where window.contains(cue.distanceKm) {
            let cueX = rect.minX + CGFloat((cue.distanceKm - window.lowerBound) / span) * rect.width
            if cue.id == selectedCueID {
                selected = (cue, cueX)
                continue
            }
            guard cueX - lastX >= minimumGap else { continue }
            icons.append((cue, cueX))
            lastX = cueX
        }
        if let selected {
            icons.append(selected)
        }
        return icons
    }

    private var displayedSelection: CourseProfileSelection? {
        if let selectedProfilePoint {
            return selectedProfilePoint
        }
        guard let selectedCue,
              let index = cueTrackIndex(selectedCue, in: course.trackPoints) else {
            return nil
        }
        return CourseProfileSelection(trackIndex: index, point: course.trackPoints[index])
    }

    private var focusedDistanceKm: Double? {
        selectedProfilePoint?.distanceKm ?? selectedCue?.distanceKm
    }

    private func loadProfileIfNeeded() {
        guard profileCourseID != course.id else { return }
        profileCourseID = course.id
        profile = MapElevationProfile(trackPoints: course.trackPoints)
        zoom = 1
        visibleStartKm = 0
    }

    private func visibleWindow(profile: MapElevationProfile) -> ClosedRange<Double> {
        let span = profile.totalKm / Double(zoom)
        let start = clampedStart(visibleStartKm, span: span, total: profile.totalKm)
        return start...(start + span)
    }

    private func clampedStart(_ start: Double, span: Double, total: Double) -> Double {
        min(max(start, 0), max(0, total - span))
    }

    /// 화면에 최소 Layout.minimumVisibleKm 까지만 확대한다.
    private func maxZoom(for profile: MapElevationProfile) -> CGFloat {
        max(1, CGFloat(profile.totalKm / Layout.minimumVisibleKm))
    }

    private func chartRect(in size: CGSize) -> CGRect {
        CGRect(
            x: Layout.leftPad,
            y: Layout.cueBandHeight,
            width: max(1, size.width - Layout.leftPad - Layout.rightPad),
            height: max(1, size.height - Layout.cueBandHeight - Layout.bottomPad)
        )
    }

    private func formatKmTick(_ km: Double, step: Double) -> String {
        let digits = step >= 1 ? 0 : (step >= 0.1 ? 1 : 2)
        return String(format: "%.\(digits)f", km)
    }

    private func formatGrade(_ grade: Double) -> String {
        String(format: "%+.1f%%", grade)
    }

    /// 길게 누르기 판정 시간과, 그동안 허용하는 손가락 이동 거리.
    static let scrubPressDuration: TimeInterval = 0.35
    static let scrubMovementTolerance: CGFloat = 10

    private enum Layout {
        static let chartHeight: CGFloat = 132
        static let leftPad: CGFloat = 30
        static let rightPad: CGFloat = 4
        static let cueBandHeight: CGFloat = 22
        static let bottomPad: CGFloat = 15
        static let cueIconRadius: CGFloat = 8
        static let minimumVisibleKm: Double = 0.5
        static let minimumSegmentWidth: CGFloat = 2
        /// 큐 가이드 라인에서 이 거리 안으로 들어오면 큐에 달라붙고, release 거리 밖으로 나가야 떨어진다.
        static let cueMagnetCaptureDistance: CGFloat = 8
        static let cueMagnetReleaseDistance: CGFloat = 14
    }
}

// MARK: - Gestures

/// 그래프 위에 겹치는 투명 뷰. 탭, 길게 누르기(+드래그), 한 손가락 이동, 핀치 확대를 UIKit 인식기로 처리한다.
private struct ChartGestureView: UIViewRepresentable {
    var onTap: (CGPoint) -> Void
    var onLongPress: (UIGestureRecognizer.State, CGPoint) -> Void
    var onPan: (UIGestureRecognizer.State, CGFloat) -> Void
    var onPinch: (UIGestureRecognizer.State, CGFloat, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let coordinator = context.coordinator
        let longPress = UILongPressGestureRecognizer(
            target: coordinator,
            action: #selector(Coordinator.handleLongPress(_:))
        )
        longPress.minimumPressDuration = MapElevationChartView.scrubPressDuration
        longPress.allowableMovement = MapElevationChartView.scrubMovementTolerance

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))

        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        // 길게 누르기가 실패(=누르자마자 움직임)했을 때만 이동으로 본다.
        pan.require(toFail: longPress)

        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch(_:)))

        [longPress, tap, pan, pinch].forEach(view.addGestureRecognizer)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject {
        var parent: ChartGestureView
        private var pinchAnchorX: CGFloat = 0

        init(parent: ChartGestureView) {
            self.parent = parent
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onTap(recognizer.location(in: recognizer.view))
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            parent.onLongPress(recognizer.state, recognizer.location(in: recognizer.view))
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            parent.onPan(recognizer.state, recognizer.translation(in: recognizer.view).x)
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .began {
                pinchAnchorX = recognizer.location(in: recognizer.view).x
            }
            parent.onPinch(recognizer.state, recognizer.scale, pinchAnchorX)
        }
    }
}

// MARK: - Grade band

/// 순간 경사도 구간. 그래프 색상과 범례에 쓴다.
enum GradeBand: CaseIterable, Hashable {
    case descent
    case flat
    case gentle
    case moderate
    case steep
    case extreme

    init(grade: Double) {
        switch grade {
        case ..<(-2): self = .descent
        case ..<2: self = .flat
        case ..<4: self = .gentle
        case ..<7: self = .moderate
        case ..<10: self = .steep
        default: self = .extreme
        }
    }

    var color: Color {
        switch self {
        case .descent: return Color(red: 0.30, green: 0.56, blue: 0.95)
        case .flat: return Color(red: 0.36, green: 0.76, blue: 0.40)
        case .gentle: return Color(red: 0.96, green: 0.82, blue: 0.20)
        case .moderate: return Color(red: 0.98, green: 0.58, blue: 0.16)
        case .steep: return Color(red: 0.90, green: 0.25, blue: 0.20)
        case .extreme: return Color(red: 0.56, green: 0.16, blue: 0.40)
        }
    }

    var legendLabel: String {
        switch self {
        case .descent: return "↓"
        case .flat: return "<2"
        case .gentle: return "2–4"
        case .moderate: return "4–7"
        case .steep: return "7–10"
        case .extreme: return "10%+"
        }
    }
}

// MARK: - Profile data

/// 고도값이 있는 트랙 포인트와 각 지점의 순간 경사도를 미리 계산해 둔다.
struct MapElevationProfile {
    struct Sample {
        var trackIndex: Int
        var km: Double
        var ele: Double
        /// 퍼센트 단위 경사도.
        var grade: Double
    }

    /// 경사도를 계산할 때 앞뒤로 보는 거리. GPS 고도 노이즈를 줄이려고 짧은 구간을 평균낸다.
    static let gradeHalfWindowKm = 0.1

    let samples: [Sample]
    let totalKm: Double
    let minEle: Double
    let maxEle: Double

    init(trackPoints: [TrackPoint]) {
        var raw: [Sample] = []
        raw.reserveCapacity(trackPoints.count)
        for (index, point) in trackPoints.enumerated() {
            guard let ele = point.ele else { continue }
            raw.append(Sample(trackIndex: index, km: point.cumKm, ele: ele, grade: 0))
        }

        // 두 포인터로 ±gradeHalfWindowKm 구간의 양 끝을 찾는다.
        var lower = 0
        var upper = 0
        for index in raw.indices {
            let km = raw[index].km
            while lower < index, raw[lower].km < km - Self.gradeHalfWindowKm {
                lower += 1
            }
            upper = max(upper, index)
            while upper + 1 < raw.count, raw[upper + 1].km <= km + Self.gradeHalfWindowKm {
                upper += 1
            }
            let a = raw[max(0, min(lower, index - 1))]
            let b = raw[min(raw.count - 1, max(upper, index + 1))]
            let meters = (b.km - a.km) * 1000
            raw[index].grade = meters > 1 ? (b.ele - a.ele) / meters * 100 : 0
        }

        samples = raw
        totalKm = max(trackPoints.last?.cumKm ?? 0, 0.001)

        let elevations = raw.map(\.ele)
        let low = elevations.min() ?? 0
        let high = elevations.max() ?? 100
        let pad = max((high - low) * 0.08, 10)
        minEle = max(0, ((low - pad) / 10).rounded(.down) * 10)
        maxEle = ((high + pad) / 10).rounded(.up) * 10
    }

    /// km 이상인 첫 샘플 인덱스.
    func lowerBound(km: Double) -> Int {
        var low = 0
        var high = samples.count
        while low < high {
            let mid = (low + high) / 2
            if samples[mid].km < km {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// 두 샘플 사이 구간의 경사도. 구간이 경사 계산 창보다 짧으면 끝 샘플의 순간 경사도를 쓴다.
    func grade(from start: Sample, to end: Sample) -> Double {
        let meters = (end.km - start.km) * 1000
        guard meters > Self.gradeHalfWindowKm * 2000 else { return end.grade }
        return (end.ele - start.ele) / meters * 100
    }

    func sample(nearestKm km: Double) -> Sample {
        let index = lowerBound(km: km)
        if index <= 0 { return samples[0] }
        if index >= samples.count { return samples[samples.count - 1] }
        let before = samples[index - 1]
        let after = samples[index]
        return km - before.km <= after.km - km ? before : after
    }
}
