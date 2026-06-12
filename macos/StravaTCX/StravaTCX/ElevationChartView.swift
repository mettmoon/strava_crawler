import SwiftUI
import AppKit
import StravaTCXKit

// MARK: - ElevationChartView

struct ElevationChartView: View {
    let trackPoints: [TrackPoint]
    var markers: [ElevationMarker] = []
    /// 외부에서 강조해서 표시할 위치 (누적 거리, km). 큐시트 항목 선택 시 사용.
    var focusedDistanceKm: Double? = nil
    @Binding var hoverInfo: RouteHoverInfo?
    /// 드래그로 선택한 구간(km). 드래그 중에도 갱신된다 (`isDragging == true`).
    var rangeSelection: Binding<ChartRangeSelection?>? = nil
    /// 호버 위치에서 우클릭 → "웨이포인트 추가" 선택 시 호출. 인자: 누적 거리(km).
    var onAddCueAtHover: ((Double) -> Void)? = nil
    /// 차트 배경(아무 곳)을 클릭했을 때 호출. 큐 포커스 해제 등에 사용.
    var onBackgroundClick: (() -> Void)? = nil

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var actualRowCount: Int = 0
    @State private var viewWidth: CGFloat = 0
    @State private var chartBodyHeight: CGFloat = 120
    @State private var showCustomPopover = false

    private let rowHeight: CGFloat = 16
    private let rowPad: CGFloat = 4
    private let minPixelsPerKm: CGFloat = 40
    private let maxScale: CGFloat = 30.0
    private let scaleStep: CGFloat = 1.4
    private let approxCharW: CGFloat = 6.5
    private let maxMarkerRows = 4

    /// 자연 너비: scale=1 일 때의 콘텐츠 폭
    private var naturalWidth: CGFloat { CGFloat(totalKm) * minPixelsPerKm }

    /// 전체 경로가 한 화면에 딱 맞는 스케일
    private var minScale: CGFloat {
        guard viewWidth > 0, naturalWidth > 0 else { return 1.0 }
        return viewWidth / naturalWidth
    }

    private var stripH: CGFloat {
        visibleRowCount == 0 ? 0 : rowPad + CGFloat(visibleRowCount) * rowHeight + rowPad
    }
    private var totalHeight: CGFloat { stripH + chartBodyHeight + 16 }
    private var visibleRowCount: Int { min(actualRowCount, maxMarkerRows) }

    var body: some View {
        GeometryReader { geo in
            // contentWidth: naturalWidth * scale, 최소 뷰 너비
            let contentWidth = max(geo.size.width, naturalWidth * scale)
            let placements = computePlacements(contentWidth: contentWidth)
            let hiddenMarkerCount = placements.filter { $0.row >= maxMarkerRows }.count

            ZStack(alignment: .bottomTrailing) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: true) {
                        Canvas { ctx, size in
                            drawChart(ctx: ctx, size: size,
                                      stripH: stripH, placements: placements,
                                      hiddenMarkerCount: hiddenMarkerCount,
                                      hoverInfo: hoverInfo,
                                      focusedDistanceKm: focusedDistanceKm,
                                      rangeSelection: rangeSelection?.wrappedValue)
                        }
                        .frame(width: contentWidth, height: stripH + chartBodyHeight)
                        .overlay(alignment: .leading) {
                            // 가로 스크롤 자동이동용 invisible anchors
                            scrollAnchors(contentWidth: contentWidth)
                        }
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                updateHover(location: location, contentWidth: contentWidth)
                            case .ended:
                                hoverInfo = nil
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { value in
                                    handleRangeDragChanged(value: value, contentWidth: contentWidth)
                                }
                                .onEnded { value in
                                    handleRangeDragEnded(value: value, contentWidth: contentWidth)
                                }
                        )
                        .onTapGesture {
                            // 빈 클릭 → 큐 포커스 + 드래그 선택 모두 해제
                            rangeSelection?.wrappedValue = nil
                            onBackgroundClick?()
                        }
                        .background(
                            WheelZoomView { delta in applyZoom(delta: delta) }
                        )
                        .overlay(
                            RightClickCatcher(onRightClick: {
                                guard let info = hoverInfo, onAddCueAtHover != nil else { return }
                                showRightClickMenu(distanceKm: info.distanceKm)
                            })
                        )
                    }
                    .onChange(of: focusedDistanceKm) { _, km in
                        guard let km, totalKm > 0 else { return }
                        let bucket = scrollAnchorBucket(forKm: km)
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(bucket, anchor: .center)
                        }
                    }
                }
                .gesture(
                    MagnifyGesture()
                        .onChanged { v in
                            scale = clamped(lastScale * v.magnification)
                        }
                        .onEnded { v in
                            scale = clamped(lastScale * v.magnification)
                            lastScale = scale
                        }
                )

                // 컨트롤 버튼
                HStack(spacing: 4) {
                    Button { scaleBy(1 / scaleStep) } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .disabled(scale <= minScale)
                    Button { scaleBy(scaleStep) } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .disabled(scale >= maxScale)

                    Divider().frame(height: 14)

                    Button {
                        showCustomPopover.toggle()
                    } label: {
                        Text("커스텀").font(.caption)
                    }
                    .popover(isPresented: $showCustomPopover, arrowEdge: .bottom) {
                        let eleSpanM: Double = {
                            let eles = trackPoints.compactMap(\.ele)
                            guard let mn = eles.min(), let mx = eles.max() else { return 100 }
                            return max(mx - mn, 1)
                        }()
                        CustomScalePopover(
                            pxPerKm: naturalWidth > 0 ? Double(naturalWidth * scale / CGFloat(totalKm)) : 40,
                            pxPerM: Double(chartBodyHeight) / eleSpanM,
                            eleSpanM: eleSpanM,
                            totalKm: totalKm,
                            onApply: { pxPerKm, pxPerM in
                                if totalKm > 0, naturalWidth > 0 {
                                    let newScale = CGFloat(pxPerKm) * CGFloat(totalKm) / naturalWidth
                                    scale = max(minScale, newScale)
                                    lastScale = scale
                                }
                                chartBodyHeight = max(40, CGFloat(pxPerM * eleSpanM))
                                recalcRowCount()
                            }
                        )
                    }
                }
                .buttonStyle(.borderless)
                .padding(5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(.trailing, 8)
                .padding(.bottom, 16)
            }
            .onAppear {
                viewWidth = geo.size.width
                resetScale()
            }
            .onChange(of: geo.size.width) { _, w in
                viewWidth = w
                scale = clamped(scale)
                lastScale = scale
                recalcRowCount()
            }
        }
        .frame(height: totalHeight)
        .onChange(of: scale)              { _, _ in recalcRowCount() }
        .onChange(of: markers)            { _, _ in recalcRowCount() }
        .onChange(of: trackPoints.count)  { _, _ in resetScale() }
    }

    // MARK: - 가로 스크롤 anchor

    /// Canvas 위에 보이지 않는 anchor 뷰를 균일하게 배치한다.
    /// `focusedDistanceKm` 변경 시 ScrollViewReader가 가장 가까운 anchor로 스크롤한다.
    @ViewBuilder
    private func scrollAnchors(contentWidth: CGFloat) -> some View {
        let count = scrollAnchorCount
        let step = contentWidth / CGFloat(max(count - 1, 1))
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                Color.clear
                    .frame(width: i == count - 1 ? 1 : step, height: 1)
                    .id(i)
            }
        }
        .frame(width: contentWidth, height: 1, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    private var scrollAnchorCount: Int { 200 }

    private func scrollAnchorBucket(forKm km: Double) -> Int {
        guard totalKm > 0 else { return 0 }
        let ratio = min(max(km / totalKm, 0), 1)
        let bucket = Int((ratio * Double(scrollAnchorCount - 1)).rounded())
        return min(max(bucket, 0), scrollAnchorCount - 1)
    }

    // MARK: - 레이블 배치 계산

    struct Placement {
        let mx: CGFloat
        let my: CGFloat   // 차트 내부 기준 y (stripH 더해야 canvas y)
        let row: Int
        let label: String
        let color: Color
    }

    private func computePlacements(contentWidth: CGFloat) -> [Placement] {
        guard !markers.isEmpty, totalKm > 0 else { return [] }
        guard let (minEle, maxEle) = eleRange, maxEle > minEle else { return [] }
        let eleSpan = maxEle - minEle

        func xPos(_ km: Double) -> CGFloat {
            CGFloat(km / totalKm) * contentWidth
        }
        func yBody(_ ele: Double) -> CGFloat {
            let vPad: CGFloat = 6
            let ratio = CGFloat((ele - minEle) / eleSpan)
            return (chartBodyHeight - vPad) - ratio * (chartBodyHeight - vPad * 2)
        }

        var raw: [(mx: CGFloat, my: CGFloat, label: String, color: Color)] = []
        for marker in markers {
            guard let idx = nearestIndex(to: marker.cumKm),
                  let ele = trackPoints[idx].ele else { continue }
            raw.append((
                mx: xPos(trackPoints[idx].cumKm),
                my: yBody(ele),
                label: marker.label,
                color: marker.color
            ))
        }
        raw.sort { $0.mx < $1.mx }

        // 각 행의 현재 오른쪽 끝 (label right edge)
        var rowRightEdge: [CGFloat] = []
        let gap: CGFloat = 6

        var result: [Placement] = []
        for r in raw {
            let labelW = CGFloat(r.label.count) * approxCharW
            let left   = r.mx - labelW / 2
            let right  = left + labelW

            // 겹치지 않는 가장 낮은 행 찾기
            var assignedRow = 0
            for row in 0... {
                if row >= rowRightEdge.count || rowRightEdge[row] + gap <= left {
                    assignedRow = row
                    break
                }
            }
            while rowRightEdge.count <= assignedRow { rowRightEdge.append(-999) }
            rowRightEdge[assignedRow] = right
            result.append(Placement(mx: r.mx, my: r.my,
                                    row: assignedRow,
                                    label: r.label, color: r.color))
        }
        return result
    }

    // MARK: - Canvas 그리기

    private func drawChart(ctx: GraphicsContext, size: CGSize,
                           stripH: CGFloat, placements: [Placement],
                           hiddenMarkerCount: Int,
                           hoverInfo: RouteHoverInfo?,
                           focusedDistanceKm: Double?,
                           rangeSelection: ChartRangeSelection?) {
        guard let (minEle, maxEle) = eleRange, maxEle > minEle else { return }
        let eleSpan  = maxEle - minEle
        let bodyTop  = stripH
        let bodyBot  = size.height
        let bodyH    = bodyBot - bodyTop
        let vPad: CGFloat = 6

        func xPos(_ km: Double) -> CGFloat {
            guard totalKm > 0 else { return 0 }
            return CGFloat(km / totalKm) * size.width
        }
        func yPos(_ ele: Double) -> CGFloat {
            let ratio = CGFloat((ele - minEle) / eleSpan)
            return bodyBot - vPad - ratio * (bodyH - vPad * 2)
        }

        // ── 고도 채우기 ────────────────────────────────────────
        let elevPts = trackPoints.compactMap { tp -> CGPoint? in
            guard let e = tp.ele else { return nil }
            return CGPoint(x: xPos(tp.cumKm), y: yPos(e))
        }
        guard elevPts.count >= 2 else { return }

        var fillPath = Path()
        fillPath.move(to: CGPoint(x: elevPts[0].x, y: bodyBot))
        elevPts.forEach { fillPath.addLine(to: $0) }
        fillPath.addLine(to: CGPoint(x: elevPts.last!.x, y: bodyBot))
        fillPath.closeSubpath()

        ctx.fill(fillPath, with: .linearGradient(
            Gradient(colors: [Color.orange.opacity(0.55), Color.orange.opacity(0.12)]),
            startPoint: CGPoint(x: 0, y: bodyTop),
            endPoint: CGPoint(x: 0, y: bodyBot)
        ))

        var linePath = Path()
        linePath.move(to: elevPts[0])
        elevPts.dropFirst().forEach { linePath.addLine(to: $0) }
        ctx.stroke(linePath, with: .color(.orange),
                   style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))

        // ── 거리 눈금 ─────────────────────────────────────────
        // 픽셀/km → 눈금 간격 선택 (눈금 간격이 최소 50px 이상이 되도록)
        let pxPerKm = totalKm > 0 ? size.width / CGFloat(totalKm) : size.width
        let minTickPx: CGFloat = 50
        let candidates: [Double] = [0.5, 1, 2, 5, 10, 20, 25, 50, 100, 200]
        let tickInterval = candidates.first { $0 * Double(pxPerKm) >= Double(minTickPx) } ?? candidates.last!

        let tickAttrs = AttributeContainer([
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ])
        let firstTick = ceil(0 / tickInterval) * tickInterval
        var km = firstTick
        while km <= totalKm + tickInterval * 0.01 {
            let tx = xPos(km)
            // 눈금선 (차트 하단 ~ bodyBot)
            var tick = Path()
            tick.move(to: CGPoint(x: tx, y: bodyBot - 8))
            tick.addLine(to: CGPoint(x: tx, y: bodyBot))
            ctx.stroke(tick, with: .color(.secondary.opacity(0.4)),
                       style: StrokeStyle(lineWidth: 0.5))
            // 눈금 레이블
            let label = km < 1 ? String(format: "%.1fkm", km) : "\(Int(km))km"
            ctx.draw(Text(AttributedString(label, attributes: tickAttrs)),
                     at: CGPoint(x: tx + 2, y: bodyBot - 9), anchor: .bottomLeading)
            km += tickInterval
        }

        // ── 고도 min/max 레이블 ────────────────────────────────
        let eleAttrs = AttributeContainer([
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        ctx.draw(Text(AttributedString("\(Int(maxEle))m", attributes: eleAttrs)),
                 at: CGPoint(x: 4, y: bodyTop + vPad), anchor: .topLeading)
        ctx.draw(Text(AttributedString("\(Int(minEle))m", attributes: eleAttrs)),
                 at: CGPoint(x: 4, y: bodyBot - vPad), anchor: .bottomLeading)

        // stripH 구분선
        if stripH > 0 {
            var div = Path()
            div.move(to: CGPoint(x: 0, y: bodyTop - 0.5))
            div.addLine(to: CGPoint(x: size.width, y: bodyTop - 0.5))
            ctx.stroke(div, with: .color(.secondary.opacity(0.2)),
                       style: StrokeStyle(lineWidth: 0.5))
        }

        // ── 마커 ──────────────────────────────────────────────
        for p in placements {
            let canvasMY = bodyTop + p.my  // canvas 좌표계

            // 수직 구분선 (차트 영역 전체)
            var vLine = Path()
            vLine.move(to: CGPoint(x: p.mx, y: bodyTop))
            vLine.addLine(to: CGPoint(x: p.mx, y: bodyBot))
            ctx.stroke(vLine, with: .color(p.color.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 1, dash: [3, 2]))

            if p.row < maxMarkerRows {
                // 레이블 y (행 기준)
                let labelY = rowPad + CGFloat(p.row) * rowHeight
                let labelW = CGFloat(p.label.count) * approxCharW
                let labelCX = p.mx  // 레이블 중앙 = 마커 x
                let labelMidY = labelY + rowHeight / 2

                // 레이블 → 차트 연결 수직선 (레이블 아래 ~ 차트 상단)
                var stem = Path()
                stem.move(to: CGPoint(x: p.mx, y: labelY + rowHeight - 1))
                stem.addLine(to: CGPoint(x: p.mx, y: bodyTop))
                ctx.stroke(stem, with: .color(p.color.opacity(0.4)),
                           style: StrokeStyle(lineWidth: 0.8))

                // 레이블 배경 pill
                let pillRect = CGRect(x: labelCX - labelW / 2 - 3,
                                      y: labelY + 1,
                                      width: labelW + 6,
                                      height: rowHeight - 3)
                ctx.fill(Path(roundedRect: pillRect, cornerRadius: 3),
                         with: .color(p.color.opacity(0.15)))

                // 레이블 텍스트
                let textAttrs = AttributeContainer([
                    .font: NSFont.systemFont(ofSize: 9, weight: .medium),
                    .foregroundColor: NSColor(p.color)
                ])
                ctx.draw(Text(AttributedString(p.label, attributes: textAttrs)),
                         at: CGPoint(x: labelCX, y: labelMidY), anchor: .center)
            }

            // 마커 점 (고도 위치)
            let r: CGFloat = 3.5
            ctx.fill(Path(ellipseIn: CGRect(x: p.mx - r, y: canvasMY - r,
                                            width: r * 2, height: r * 2)),
                     with: .color(p.color))
        }

        if hiddenMarkerCount > 0, stripH > 0 {
            let label = "+\(hiddenMarkerCount)"
            let attrs = AttributeContainer([
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            let labelW = CGFloat(label.count) * approxCharW + 10
            let rect = CGRect(x: size.width - labelW - 6,
                              y: rowPad,
                              width: labelW,
                              height: rowHeight - 3)
            ctx.fill(Path(roundedRect: rect, cornerRadius: 3),
                     with: .color(.secondary.opacity(0.12)))
            ctx.draw(Text(AttributedString(label, attributes: attrs)),
                     at: CGPoint(x: rect.midX, y: rect.midY),
                     anchor: .center)
        }

        // ── 드래그 선택 구간 (큐시트 마커보다 아래) ────────────
        if let rangeSelection, rangeSelection.lengthKm > 0 {
            let lo = rangeSelection.lowerKm
            let hi = rangeSelection.upperKm
            let x1 = min(max(xPos(lo), 0), size.width)
            let x2 = min(max(xPos(hi), 0), size.width)
            let bandColor = Color.indigo

            // 음영 밴드
            let bandRect = CGRect(x: min(x1, x2), y: bodyTop,
                                  width: abs(x2 - x1), height: bodyBot - bodyTop)
            ctx.fill(Path(bandRect),
                     with: .color(bandColor.opacity(rangeSelection.isDragging ? 0.18 : 0.13)))

            // 양 끝 수직선
            for x in [x1, x2] {
                var line = Path()
                line.move(to: CGPoint(x: x, y: bodyTop))
                line.addLine(to: CGPoint(x: x, y: bodyBot))
                ctx.stroke(line,
                           with: .color(bandColor.opacity(0.85)),
                           style: StrokeStyle(lineWidth: 1.5))
            }

            // 양 끝 점 + 레이블 (거리 / 고도)
            let labelAttrs = AttributeContainer([
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white
            ])

            func endpointLabel(km: Double) -> String {
                let info = routeHoverInfo(trackPoints: trackPoints, nearestToDistanceKm: km)
                let dist = formatRouteDistance(km)
                let ele = formatRouteElevation(info?.elevationMeters)
                return "\(dist) · \(ele)"
            }

            for (km, x, isStart) in [(lo, x1, true), (hi, x2, false)] {
                let info = routeHoverInfo(trackPoints: trackPoints, nearestToDistanceKm: km)
                let py = info?.elevationMeters.map { yPos($0) } ?? (bodyTop + (bodyBot - bodyTop) / 2)
                let dotR: CGFloat = 4.5
                ctx.fill(Path(ellipseIn: CGRect(
                    x: x - dotR, y: py - dotR,
                    width: dotR * 2, height: dotR * 2
                )), with: .color(bandColor))
                ctx.stroke(Path(ellipseIn: CGRect(
                    x: x - dotR, y: py - dotR,
                    width: dotR * 2, height: dotR * 2
                )), with: .color(.white), style: StrokeStyle(lineWidth: 1.5))

                // 레이블 pill — 차트 상단(stripH 바로 아래)에 부착
                let labelText = endpointLabel(km: km)
                let labelW = max(56, CGFloat(labelText.count) * 6.5 + 10)
                let labelH: CGFloat = 16
                var labelX = isStart ? x - labelW - 4 : x + 4
                if labelX < 2 { labelX = x + 4 }
                if labelX + labelW > size.width - 2 { labelX = x - labelW - 4 }
                labelX = min(max(labelX, 2), size.width - labelW - 2)
                let labelY = bodyTop + 4
                let labelRect = CGRect(x: labelX, y: labelY, width: labelW, height: labelH)
                ctx.fill(Path(roundedRect: labelRect, cornerRadius: 3),
                         with: .color(bandColor.opacity(0.92)))
                ctx.draw(Text(AttributedString(labelText, attributes: labelAttrs)),
                         at: CGPoint(x: labelRect.midX, y: labelRect.midY),
                         anchor: .center)
            }

            // 중앙에 길이 레이블
            let midX = (x1 + x2) / 2
            let lengthText = "Δ \(formatRouteDistance(rangeSelection.lengthKm))"
            let lengthW = max(60, CGFloat(lengthText.count) * 6.5 + 12)
            let lengthH: CGFloat = 16
            let lengthRect = CGRect(
                x: min(max(midX - lengthW / 2, 2), size.width - lengthW - 2),
                y: bodyBot - lengthH - 4,
                width: lengthW, height: lengthH
            )
            ctx.fill(Path(roundedRect: lengthRect, cornerRadius: 3),
                     with: .color(bandColor.opacity(0.92)))
            ctx.draw(Text(AttributedString(lengthText, attributes: labelAttrs)),
                     at: CGPoint(x: lengthRect.midX, y: lengthRect.midY),
                     anchor: .center)
        }

        // ── 큐시트 선택 마커 (호버보다 먼저 그려서, 호버가 위에 오도록) ─
        if let focusedDistanceKm,
           let focusedInfo = routeHoverInfo(trackPoints: trackPoints,
                                            nearestToDistanceKm: focusedDistanceKm),
           let focusedEle = focusedInfo.elevationMeters {
            let fx = min(max(xPos(focusedInfo.distanceKm), 0), size.width)
            let fy = min(max(yPos(focusedEle), bodyTop), bodyBot)
            let focusColor = Color.pink

            var fLine = Path()
            fLine.move(to: CGPoint(x: fx, y: bodyTop))
            fLine.addLine(to: CGPoint(x: fx, y: bodyBot))
            ctx.stroke(fLine, with: .color(focusColor.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 1.5))

            let outerR: CGFloat = 7
            ctx.fill(Path(ellipseIn: CGRect(
                x: fx - outerR, y: fy - outerR,
                width: outerR * 2, height: outerR * 2
            )), with: .color(focusColor.opacity(0.25)))
            let innerR: CGFloat = 4
            ctx.fill(Path(ellipseIn: CGRect(
                x: fx - innerR, y: fy - innerR,
                width: innerR * 2, height: innerR * 2
            )), with: .color(focusColor))
            ctx.stroke(Path(ellipseIn: CGRect(
                x: fx - innerR, y: fy - innerR,
                width: innerR * 2, height: innerR * 2
            )), with: .color(.white), style: StrokeStyle(lineWidth: 1.2))
        }

        if let hoverInfo,
           let elevation = hoverInfo.elevationMeters {
            let hoverX = min(max(xPos(hoverInfo.distanceKm), 0), size.width)
            let hoverY = min(max(yPos(elevation), bodyTop), bodyBot)
            let guideColor = Color.cyan.opacity(0.72)

            var vLine = Path()
            vLine.move(to: CGPoint(x: hoverX, y: bodyTop))
            vLine.addLine(to: CGPoint(x: hoverX, y: bodyBot))
            ctx.stroke(vLine, with: .color(guideColor),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            var hLine = Path()
            hLine.move(to: CGPoint(x: 0, y: hoverY))
            hLine.addLine(to: CGPoint(x: size.width, y: hoverY))
            ctx.stroke(hLine, with: .color(guideColor),
                       style: StrokeStyle(lineWidth: 1, dash: [4, 3]))

            let dotR: CGFloat = 4
            ctx.fill(Path(ellipseIn: CGRect(
                x: hoverX - dotR,
                y: hoverY - dotR,
                width: dotR * 2,
                height: dotR * 2
            )), with: .color(.cyan))

            let bubbleW: CGFloat = 104
            let bubbleH: CGFloat = 58
            var bubbleX = hoverX + 10
            if bubbleX + bubbleW > size.width - 6 {
                bubbleX = hoverX - bubbleW - 10
            }
            var bubbleY = hoverY - bubbleH - 10
            if bubbleY < bodyTop + 6 {
                bubbleY = hoverY + 10
            }
            if bubbleY + bubbleH > bodyBot - 6 {
                bubbleY = bodyBot - bubbleH - 6
            }
            bubbleX = min(max(bubbleX, 6), size.width - bubbleW - 6)
            bubbleY = min(max(bubbleY, bodyTop + 6), bodyBot - bubbleH - 6)

            let bubbleRect = CGRect(x: bubbleX, y: bubbleY, width: bubbleW, height: bubbleH)
            ctx.fill(Path(roundedRect: bubbleRect, cornerRadius: 4),
                     with: .color(Color(nsColor: .windowBackgroundColor).opacity(0.96)))
            ctx.stroke(Path(roundedRect: bubbleRect, cornerRadius: 4),
                       with: .color(.secondary.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 0.8))

            let attrs = AttributeContainer([
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ])
            let distanceText = formatRouteDistance(hoverInfo.distanceKm)
            let elevationText = formatRouteElevation(hoverInfo.elevationMeters)
            let gradeText = formatRouteGrade(hoverInfo.gradePercent)
            ctx.draw(Text(AttributedString(distanceText, attributes: attrs)),
                     at: CGPoint(x: bubbleRect.midX, y: bubbleRect.minY + 13),
                     anchor: .center)
            ctx.draw(Text(AttributedString(elevationText, attributes: attrs)),
                     at: CGPoint(x: bubbleRect.midX, y: bubbleRect.minY + 29),
                     anchor: .center)
            ctx.draw(Text(AttributedString(gradeText, attributes: attrs)),
                     at: CGPoint(x: bubbleRect.midX, y: bubbleRect.minY + 45),
                     anchor: .center)
        }
    }

    // MARK: - 헬퍼

    private var totalKm: Double { trackPoints.last?.cumKm ?? 1 }

    private var eleRange: (Double, Double)? {
        let eles = trackPoints.compactMap(\.ele)
        guard let mn = eles.min(), let mx = eles.max() else { return nil }
        let pad = max((mx - mn) * 0.08, 8)
        return (mn - pad, mx + pad)
    }

    private func nearestIndex(to km: Double) -> Int? {
        guard !trackPoints.isEmpty else { return nil }
        var best = 0
        var bestDist = Double.infinity
        for (i, tp) in trackPoints.enumerated() {
            let d = abs(tp.cumKm - km)
            if d < bestDist { bestDist = d; best = i }
        }
        return best
    }

    // MARK: - 드래그 구간 선택

    private func kmAtX(_ x: CGFloat, contentWidth: CGFloat) -> Double {
        guard contentWidth > 0, totalKm > 0 else { return 0 }
        let clampedX = min(max(x, 0), contentWidth)
        return Double(clampedX / contentWidth) * totalKm
    }

    private func handleRangeDragChanged(value: DragGesture.Value, contentWidth: CGFloat) {
        guard let binding = rangeSelection else { return }
        let startKm = kmAtX(value.startLocation.x, contentWidth: contentWidth)
        let endKm = kmAtX(value.location.x, contentWidth: contentWidth)
        binding.wrappedValue = ChartRangeSelection(
            startKm: startKm,
            endKm: endKm,
            isDragging: true
        )
        // 드래그 중 hover 마커도 함께 따라가도록
        hoverInfo = routeHoverInfo(trackPoints: trackPoints, nearestToDistanceKm: endKm)
    }

    private func handleRangeDragEnded(value: DragGesture.Value, contentWidth: CGFloat) {
        guard let binding = rangeSelection else { return }
        let startKm = kmAtX(value.startLocation.x, contentWidth: contentWidth)
        let endKm = kmAtX(value.location.x, contentWidth: contentWidth)
        // 너무 짧은 드래그(거의 클릭)는 셀렉션 무시
        let lengthKm = abs(endKm - startKm)
        let minKm = max(totalKm * 0.001, 0.005)
        if lengthKm < minKm {
            binding.wrappedValue = nil
            return
        }
        binding.wrappedValue = ChartRangeSelection(
            startKm: startKm,
            endKm: endKm,
            isDragging: false
        )
    }

    private func updateHover(location: CGPoint, contentWidth: CGFloat) {
        guard !trackPoints.isEmpty, totalKm > 0, contentWidth > 0 else {
            hoverInfo = nil
            return
        }
        let x = min(max(location.x, 0), contentWidth)
        let km = Double(x / contentWidth) * totalKm
        hoverInfo = routeHoverInfo(trackPoints: trackPoints, nearestToDistanceKm: km)
    }

    private func clamped(_ s: CGFloat) -> CGFloat {
        min(maxScale, max(minScale, s))
    }

    private func applyZoom(delta: CGFloat) {
        scale = clamped(scale * (1 + delta * 0.06))
        lastScale = scale
    }

    private func scaleBy(_ factor: CGFloat) {
        scale = clamped(scale * factor)
        lastScale = scale
    }

    private func resetScale() {
        scale = minScale
        lastScale = minScale
        recalcRowCount()
    }

    private func recalcRowCount() {
        let w = max(viewWidth > 0 ? viewWidth : 1000, naturalWidth * scale)
        let p = computePlacements(contentWidth: w)
        actualRowCount = (p.map(\.row).max() ?? -1) + 1
    }

    // MARK: - 우클릭 메뉴

    private func showRightClickMenu(distanceKm: Double) {
        guard let onAddCueAtHover else { return }
        let menu = NSMenu()
        let target = MenuActionTarget { onAddCueAtHover(distanceKm) }
        let item = NSMenuItem(title: "웨이포인트 추가", action: #selector(MenuActionTarget.fire), keyEquivalent: "")
        item.target = target
        menu.addItem(item)
        // target은 popUpContextMenu 동안 retain되어야 한다.
        objc_setAssociatedObject(menu, &MenuActionTarget.assocKey, target, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if let event = NSApp.currentEvent, let view = event.window?.contentView {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }
    }
}

private final class MenuActionTarget: NSObject {
    static var assocKey: UInt8 = 0
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

// MARK: - 우클릭 캡처

private struct RightClickCatcher: NSViewRepresentable {
    var onRightClick: () -> Void

    func makeNSView(context: Context) -> _RightClickView {
        _RightClickView(onRightClick: onRightClick)
    }
    func updateNSView(_ v: _RightClickView, context: Context) { v.onRightClick = onRightClick }

    final class _RightClickView: NSView {
        var onRightClick: () -> Void
        init(onRightClick: @escaping () -> Void) {
            self.onRightClick = onRightClick
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? {
            // 우클릭만 가로채고, 다른 마우스 이벤트는 아래로 통과시킨다.
            if let event = NSApp.currentEvent {
                switch event.type {
                case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
                    return self
                default:
                    return nil
                }
            }
            return nil
        }

        override func rightMouseDown(with event: NSEvent) {
            onRightClick()
        }
    }
}

// MARK: - 마우스 휠 줌

private struct WheelZoomView: NSViewRepresentable {
    var onDelta: (CGFloat) -> Void

    func makeNSView(context: Context) -> _WheelView { _WheelView(onDelta: onDelta) }
    func updateNSView(_ v: _WheelView, context: Context) { v.onDelta = onDelta }

    class _WheelView: NSView {
        var onDelta: (CGFloat) -> Void
        init(onDelta: @escaping (CGFloat) -> Void) {
            self.onDelta = onDelta
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func scrollWheel(with event: NSEvent) {
            if !event.hasPreciseScrollingDeltas {
                // 마우스 클릭 휠 → 줌
                onDelta(-event.scrollingDeltaY)
            } else {
                // 트랙패드 두 손가락 스크롤 → ScrollView 에 위임
                super.scrollWheel(with: event)
            }
        }
    }
}

// MARK: - CustomScalePopover

private struct CustomScalePopover: View {
    let pxPerKm: Double
    let pxPerM: Double
    let eleSpanM: Double
    let totalKm: Double
    let onApply: (Double, Double) -> Void

    @State private var pxPerKmText: String = ""
    @State private var pxPerMText: String = ""
    @Environment(\.dismiss) private var dismiss

    private var previewKmPt: String {
        let v = Double(pxPerKmText) ?? pxPerKm
        return String(format: "총 %.0fkm → %.0fpt", totalKm, v * totalKm)
    }
    private var previewMPt: String {
        let v = Double(pxPerMText) ?? pxPerM
        return String(format: "고도차 %.0fm → %.0fpt", eleSpanM, v * eleSpanM)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("커스텀 비율").font(.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("거리").foregroundStyle(.secondary).font(.caption)
                    HStack(spacing: 4) {
                        TextField("", text: $pxPerKmText)
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                        Text("pt / km").font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text(previewKmPt).font(.caption).foregroundStyle(.tertiary)
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text("고도").foregroundStyle(.secondary).font(.caption)
                    HStack(spacing: 4) {
                        TextField("", text: $pxPerMText)
                            .frame(width: 70)
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.trailing)
                        Text("pt / m").font(.caption).foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text(previewMPt).font(.caption).foregroundStyle(.tertiary)
                }
            }

            HStack {
                Button("취소") { dismiss() }
                Spacer()
                Button("적용") {
                    let newPxKm = Double(pxPerKmText) ?? pxPerKm
                    let newPxM  = Double(pxPerMText)  ?? pxPerM
                    onApply(newPxKm, newPxM)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear {
            pxPerKmText = String(format: "%.2f", pxPerKm)
            pxPerMText  = String(format: "%.3f", pxPerM)
        }
    }
}

// MARK: - ElevationMarker

struct ElevationMarker: Identifiable, Equatable {
    var id: String
    var cumKm: Double
    var label: String
    var color: Color
}
