import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ElevationProfileScale: Equatable {
    var distanceFactor: CGFloat
    var elevationFactor: CGFloat

    static let standardFactor: CGFloat = 0.5
    static let minimumFactor: CGFloat = 0.000001
    static let standard = ElevationProfileScale(distanceFactor: standardFactor, elevationFactor: standardFactor)
}

struct ElevationProfileView: View {
    let trackPoints: [TrackPoint]
    let cuePoints: [CourseCuePoint]
    let selectedCueID: UUID?
    let selectedProfilePoint: CourseProfileSelection?
    var contentWidth: CGFloat = 0
    var visibleWidth: CGFloat = 0
    var horizontalOffset: CGFloat = 0
    var onSelectProfilePoint: (CourseProfileSelection) -> Void = { _ in }
    var onSelectCue: (UUID) -> Void = { _ in }

    private var elevationPoints: [TrackPoint] {
        trackPoints.filter { $0.ele != nil }
    }

    static func preferredSize(
        trackPoints: [TrackPoint],
        availableWidth: CGFloat,
        scale: ElevationProfileScale
    ) -> CGSize {
        let availableWidth = max(1, availableWidth)
        guard let elevationRange = elevationRangeMeters(trackPoints: trackPoints) else {
            return CGSize(width: availableWidth, height: ElevationProfileLayout.emptyHeight)
        }

        let baseChartWidth = max(
            1,
            availableWidth - ElevationProfileLayout.leftPad - ElevationProfileLayout.rightPad
        )
        let chartWidth = baseChartWidth * max(ElevationProfileScale.minimumFactor, scale.elevationFactor)
        let pixelsPerKm = baseChartWidth / CGFloat(max(1, elevationRange) / 100)
        let chartHeight = max(
            1,
            CGFloat(max(trackPoints.last?.cumKm ?? 0, 0)) * pixelsPerKm * max(ElevationProfileScale.minimumFactor, scale.distanceFactor)
        )

        return CGSize(
            width: chartWidth + ElevationProfileLayout.leftPad + ElevationProfileLayout.rightPad,
            height: chartHeight + ElevationProfileLayout.topPad + ElevationProfileLayout.bottomPad
        )
    }

    static var headerHeight: CGFloat {
        ElevationProfileLayout.headerHeight
    }

    static func yPosition(
        distanceKm: Double,
        trackPoints: [TrackPoint],
        profileHeight: CGFloat
    ) -> CGFloat {
        let totalKm = max(trackPoints.last?.cumKm ?? 0, 0.001)
        let ratio = min(max(distanceKm / totalKm, 0), 1)
        let chartHeight = max(1, profileHeight - ElevationProfileLayout.topPad - ElevationProfileLayout.bottomPad)
        return ElevationProfileLayout.topPad + CGFloat(ratio) * chartHeight
    }

    static func fittingScale(
        trackPoints: [TrackPoint],
        availableWidth: CGFloat,
        availableHeight: CGFloat
    ) -> ElevationProfileScale {
        let availableWidth = max(1, availableWidth)
        let availableHeight = max(1, availableHeight)
        guard let elevationRange = elevationRangeMeters(trackPoints: trackPoints) else {
            return .standard
        }

        let baseChartWidth = max(
            1,
            availableWidth - ElevationProfileLayout.leftPad - ElevationProfileLayout.rightPad
        )
        let availableChartHeight = max(
            1,
            availableHeight - ElevationProfileLayout.topPad - ElevationProfileLayout.bottomPad
        )
        let pixelsPerKm = baseChartWidth / CGFloat(max(1, elevationRange) / 100)
        let chartHeightAtFullScale = CGFloat(max(trackPoints.last?.cumKm ?? 0, 0)) * pixelsPerKm
        let distanceFactor = chartHeightAtFullScale > 0
            ? availableChartHeight / chartHeightAtFullScale
            : ElevationProfileScale.standardFactor

        return ElevationProfileScale(
            distanceFactor: min(1, max(ElevationProfileScale.minimumFactor, distanceFactor)),
            elevationFactor: 1
        )
    }

    var body: some View {
        if elevationPoints.count < 2 {
            ContentUnavailableView {
                Label("고도 데이터 없음", systemImage: "mountain.2")
            } description: {
                Text("이 파일에는 표시할 고도값이 없습니다.")
            }
            .frame(maxWidth: .infinity, minHeight: ElevationProfileLayout.emptyHeight)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        } else {
            GeometryReader { proxy in
                Canvas { context, size in
                    drawProfile(context: context, size: size)
                }
                .contentShape(Rectangle())
                .simultaneousGesture(
                    SpatialTapGesture(coordinateSpace: .local)
                        .onEnded { value in
                            if let cue = cueHit(at: value.location, size: proxy.size) {
                                onSelectCue(cue.id)
                                return
                            }
                            guard let selection = profileSelection(at: value.location, size: proxy.size) else { return }
                            onSelectProfilePoint(selection)
                        }
                )
            }
        }
    }

    private func drawProfile(context: GraphicsContext, size: CGSize) {
        let chartContentWidth = contentWidth > 0 ? contentWidth : size.width
        let chartRect = CGRect(
            x: ElevationProfileLayout.leftPad,
            y: ElevationProfileLayout.topPad,
            width: max(1, chartContentWidth - ElevationProfileLayout.leftPad - ElevationProfileLayout.rightPad),
            height: max(1, size.height - ElevationProfileLayout.topPad - ElevationProfileLayout.bottomPad)
        )

        guard let bounds = ElevationProfileView.elevationBounds(trackPoints: trackPoints) else { return }
        let minEle = bounds.minimum
        let maxEle = bounds.maximum

        let totalKm = max(trackPoints.last?.cumKm ?? 0, 0.001)

        func xPosition(_ ele: Double) -> CGFloat {
            let ratio = min(max(CGFloat((ele - minEle) / (maxEle - minEle)), 0), 1)
            return chartRect.minX + ratio * chartRect.width
        }

        func yPosition(_ km: Double) -> CGFloat {
            chartRect.minY + CGFloat(km / totalKm) * chartRect.height
        }

        drawGrid(context: context, chartRect: chartRect, totalKm: totalKm, minEle: minEle, maxEle: maxEle)

        let points = elevationPoints.compactMap { point -> CGPoint? in
            guard let ele = point.ele else { return nil }
            return CGPoint(x: xPosition(ele), y: yPosition(point.cumKm))
        }
        guard let firstPoint = points.first, let lastPoint = points.last else { return }

        var fill = Path()
        fill.move(to: CGPoint(x: chartRect.minX, y: firstPoint.y))
        fill.addLine(to: firstPoint)
        for point in points {
            fill.addLine(to: point)
        }
        fill.addLine(to: CGPoint(x: chartRect.minX, y: lastPoint.y))
        fill.closeSubpath()

        context.fill(
            fill,
            with: .linearGradient(
                Gradient(colors: [Color.orange.opacity(0.42), Color.orange.opacity(0.10)]),
                startPoint: CGPoint(x: chartRect.maxX, y: 0),
                endPoint: CGPoint(x: chartRect.minX, y: 0)
            )
        )

        var line = Path()
        line.move(to: firstPoint)
        for point in points.dropFirst() {
            line.addLine(to: point)
        }
        context.stroke(line, with: .color(.orange), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

        let cuePlacements = cueLabelPlacements(chartRect: chartRect, yPosition: yPosition)
        let cueLabelX = fixedCueLabelX(chartRect: chartRect, canvasWidth: size.width)

        for placement in cuePlacements {
            let cue = placement.cue
            let selected = cue.id == selectedCueID
            let glyph = cuePointGlyph(for: cue.pointType)
            let guideEndX = cueGuideEndX(
                for: placement,
                labelX: cueLabelX,
                chartRect: chartRect,
                canvasWidth: size.width,
                selected: selected
            )
            let y = placement.guideY
            var marker = Path()
            marker.move(to: CGPoint(x: chartRect.minX, y: y))
            marker.addLine(to: CGPoint(x: guideEndX, y: y))
            context.stroke(
                marker,
                with: .color(selected ? glyph.color : glyph.color.opacity(0.45)),
                style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [4, 3])
            )
        }

        for placement in cuePlacements where placement.cue.id != selectedCueID {
            drawCueLabel(placement, context: context, x: cueLabelX, selected: false)
        }

        if let selectedPlacement = cuePlacements.first(where: { $0.cue.id == selectedCueID }) {
            drawCueLabel(selectedPlacement, context: context, x: cueLabelX, selected: true)
        }

        if let selectedProfilePoint {
            drawProfileSelection(
                selectedProfilePoint,
                context: context,
                chartRect: chartRect,
                canvasWidth: size.width,
                xPosition: xPosition,
                yPosition: yPosition
            )
        }

    }

    private func drawGrid(
        context: GraphicsContext,
        chartRect: CGRect,
        totalKm: Double,
        minEle: Double,
        maxEle: Double
    ) {
        let border = Path(roundedRect: chartRect, cornerRadius: 4)
        context.stroke(border, with: .color(.secondary.opacity(0.18)), lineWidth: 1)

        var elevation = ceil(minEle / 100) * 100
        while elevation < maxEle {
            let ratio = CGFloat((elevation - minEle) / (maxEle - minEle))
            let x = chartRect.minX + ratio * chartRect.width
            var path = Path()
            path.move(to: CGPoint(x: x, y: chartRect.minY))
            path.addLine(to: CGPoint(x: x, y: chartRect.maxY))
            context.stroke(path, with: .color(.secondary.opacity(0.14)), lineWidth: 0.5)
            elevation += 100
        }

        var km = 0.0
        while km <= totalKm + 0.001 {
            let y = chartRect.minY + CGFloat(km / totalKm) * chartRect.height
            var line = Path()
            line.move(to: CGPoint(x: chartRect.minX, y: y))
            line.addLine(to: CGPoint(x: chartRect.maxX, y: y))
            context.stroke(line, with: .color(.secondary.opacity(0.10)), lineWidth: 0.5)

            var tick = Path()
            tick.move(to: CGPoint(x: chartRect.minX - 5, y: y))
            tick.addLine(to: CGPoint(x: chartRect.minX, y: y))
            context.stroke(tick, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
            context.draw(
                Text(formatTick(km)).font(.caption2).foregroundStyle(.secondary),
                at: CGPoint(x: chartRect.minX - 8, y: y),
                anchor: .trailing
            )
            km += 1
        }

    }

    private func cueLabelPlacements(
        chartRect: CGRect,
        yPosition: (Double) -> CGFloat
    ) -> [CueLabelPlacement] {
        let items = cuePoints.map { cue in
            CueLabelPlacement(
                cue: cue,
                guideY: min(max(yPosition(cue.distanceKm), chartRect.minY), chartRect.maxY),
                labelY: min(max(yPosition(cue.distanceKm), chartRect.minY + 8), chartRect.maxY - 8)
            )
        }
        .sorted { $0.guideY < $1.guideY }

        guard items.count > 1 else { return items }

        let availableHeight = max(1, chartRect.height - 16)
        let spacing = min(18, max(8, availableHeight / CGFloat(items.count - 1)))
        var placements = items

        for index in placements.indices.dropFirst() {
            let previous = placements[index - 1].labelY
            placements[index].labelY = max(placements[index].labelY, previous + spacing)
        }

        if let last = placements.indices.last {
            let overflow = placements[last].labelY - (chartRect.maxY - 8)
            if overflow > 0 {
                for index in placements.indices {
                    placements[index].labelY -= overflow
                }
            }
        }

        for index in placements.indices.dropLast().reversed() {
            let next = placements[index + 1].labelY
            placements[index].labelY = min(placements[index].labelY, next - spacing)
        }

        for index in placements.indices {
            placements[index].labelY = min(max(placements[index].labelY, chartRect.minY + 8), chartRect.maxY - 8)
        }

        return placements
    }

    private func drawCueLabel(
        _ placement: CueLabelPlacement,
        context: GraphicsContext,
        x: CGFloat,
        selected: Bool
    ) {
        let cue = placement.cue
        let glyph = cuePointGlyph(for: cue.pointType)
        let color = selected ? glyph.color : glyph.color.opacity(0.86)
        let label = cueProfileLabel(cue.displayName)
        let weight: Font.Weight = selected ? .bold : .semibold

        context.draw(
            Text(label).font(.caption2.weight(weight)).foregroundStyle(color),
            at: CGPoint(x: x, y: placement.labelY),
            anchor: .trailing
        )
    }

    private func drawProfileSelection(
        _ selection: CourseProfileSelection,
        context: GraphicsContext,
        chartRect: CGRect,
        canvasWidth: CGFloat,
        xPosition: (Double) -> CGFloat,
        yPosition: (Double) -> CGFloat
    ) {
        guard let elevation = selection.elevationMeters else { return }

        let x = min(max(xPosition(elevation), chartRect.minX), chartRect.maxX)
        let y = min(max(yPosition(selection.distanceKm), chartRect.minY), chartRect.maxY)
        let color = Color.cyan

        var vertical = Path()
        vertical.move(to: CGPoint(x: x, y: chartRect.minY))
        vertical.addLine(to: CGPoint(x: x, y: chartRect.maxY))
        context.stroke(
            vertical,
            with: .color(color.opacity(0.72)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
        )

        var horizontal = Path()
        horizontal.move(to: CGPoint(x: chartRect.minX, y: y))
        horizontal.addLine(to: CGPoint(x: fixedCueGuideEndX(chartRect: chartRect, canvasWidth: canvasWidth), y: y))
        context.stroke(
            horizontal,
            with: .color(color.opacity(0.72)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
        )

        let dotRadius: CGFloat = 4
        context.fill(
            Path(ellipseIn: CGRect(
                x: x - dotRadius,
                y: y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )),
            with: .color(color)
        )
        context.stroke(
            Path(ellipseIn: CGRect(
                x: x - dotRadius,
                y: y - dotRadius,
                width: dotRadius * 2,
                height: dotRadius * 2
            )),
            with: .color(.white),
            lineWidth: 1
        )

        drawProfileSelectionBubble(
            selection,
            context: context,
            point: CGPoint(x: x, y: y),
            chartRect: chartRect,
            canvasWidth: canvasWidth
        )
    }

    private func drawProfileSelectionBubble(
        _ selection: CourseProfileSelection,
        context: GraphicsContext,
        point: CGPoint,
        chartRect: CGRect,
        canvasWidth: CGFloat
    ) {
        let bubbleSize = CGSize(width: 112, height: 44)
        let maxX = max(canvasWidth, chartRect.maxX)
        var origin = CGPoint(x: point.x + 10, y: point.y - bubbleSize.height - 10)
        if origin.x + bubbleSize.width > maxX - 6 {
            origin.x = point.x - bubbleSize.width - 10
        }
        if origin.y < chartRect.minY + 6 {
            origin.y = point.y + 10
        }
        origin.x = min(max(origin.x, chartRect.minX + 6), maxX - bubbleSize.width - 6)
        origin.y = min(max(origin.y, chartRect.minY + 6), chartRect.maxY - bubbleSize.height - 6)

        let rect = CGRect(origin: origin, size: bubbleSize)
        context.fill(
            Path(roundedRect: rect, cornerRadius: 5),
            with: .color(Color(.secondarySystemGroupedBackground).opacity(0.96))
        )
        context.stroke(
            Path(roundedRect: rect, cornerRadius: 5),
            with: .color(.secondary.opacity(0.35)),
            lineWidth: 0.8
        )

        context.draw(
            Text(formatRouteDistance(selection.distanceKm))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary),
            at: CGPoint(x: rect.midX, y: rect.minY + 14),
            anchor: .center
        )
        context.draw(
            Text(formatRouteElevation(selection.elevationMeters))
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary),
            at: CGPoint(x: rect.midX, y: rect.minY + 31),
            anchor: .center
        )
    }

    private func profileSelection(at location: CGPoint, size: CGSize) -> CourseProfileSelection? {
        let chartRect = chartRect(for: size)
        guard chartRect.height > 0 else { return nil }
        let totalKm = max(trackPoints.last?.cumKm ?? 0, 0.001)
        let y = min(max(location.y, chartRect.minY), chartRect.maxY)
        let distanceKm = Double((y - chartRect.minY) / chartRect.height) * totalKm
        return nearestElevationSelection(to: distanceKm)
    }

    private func nearestElevationSelection(to distanceKm: Double) -> CourseProfileSelection? {
        var bestIndex: Int?
        var bestDistance = Double.infinity
        for (index, point) in trackPoints.enumerated() where point.ele != nil {
            let distance = abs(point.cumKm - distanceKm)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        guard let bestIndex else { return nil }
        return CourseProfileSelection(trackIndex: bestIndex, point: trackPoints[bestIndex])
    }

    private func cueHit(at location: CGPoint, size: CGSize) -> CourseCuePoint? {
        let chartRect = chartRect(for: size)
        let totalKm = max(trackPoints.last?.cumKm ?? 0, 0.001)
        func yPosition(_ km: Double) -> CGFloat {
            chartRect.minY + CGFloat(km / totalKm) * chartRect.height
        }

        let placements = cueLabelPlacements(chartRect: chartRect, yPosition: yPosition)
        let labelX = fixedCueLabelX(chartRect: chartRect, canvasWidth: size.width)

        for placement in placements.reversed() {
            let selected = placement.cue.id == selectedCueID
            let label = cueProfileLabel(placement.cue.displayName)
            let labelWidth = cueLabelWidth(label, selected: selected)
            let labelRect = CGRect(
                x: labelX - labelWidth - 6,
                y: placement.labelY - 10,
                width: labelWidth + 10,
                height: 20
            )
            if labelRect.contains(location) {
                return placement.cue
            }

            let guideEndX = cueGuideEndX(
                for: placement,
                labelX: labelX,
                chartRect: chartRect,
                canvasWidth: size.width,
                selected: selected
            )
            if abs(location.y - placement.guideY) <= 5,
               location.x >= chartRect.minX,
               location.x <= guideEndX {
                return placement.cue
            }
        }

        return nil
    }

    private func chartRect(for size: CGSize) -> CGRect {
        let chartContentWidth = contentWidth > 0 ? contentWidth : size.width
        return CGRect(
            x: ElevationProfileLayout.leftPad,
            y: ElevationProfileLayout.topPad,
            width: max(1, chartContentWidth - ElevationProfileLayout.leftPad - ElevationProfileLayout.rightPad),
            height: max(1, size.height - ElevationProfileLayout.topPad - ElevationProfileLayout.bottomPad)
        )
    }

    private func cueGuideEndX(
        for placement: CueLabelPlacement,
        labelX: CGFloat,
        chartRect: CGRect,
        canvasWidth: CGFloat,
        selected: Bool
    ) -> CGFloat {
        let guideEndX = fixedCueGuideEndX(chartRect: chartRect, canvasWidth: canvasWidth)
        let label = cueProfileLabel(placement.cue.displayName)
        let labelLeftX = labelX - cueLabelWidth(label, selected: selected)
        return max(chartRect.minX, min(guideEndX, labelLeftX - ElevationProfileLayout.cueLabelGuideGap))
    }

    private func cueLabelWidth(_ label: String, selected: Bool) -> CGFloat {
        #if canImport(UIKit)
        let baseFont = UIFont.preferredFont(forTextStyle: .caption2)
        let font = UIFont.systemFont(
            ofSize: baseFont.pointSize,
            weight: selected ? .bold : .semibold
        )
        return ceil((label as NSString).size(withAttributes: [.font: font]).width)
        #else
        return CGFloat(label.count) * (selected ? 6.8 : 6.5)
        #endif
    }

    private func fixedCueGuideEndX(chartRect: CGRect, canvasWidth: CGFloat) -> CGFloat {
        guard visibleWidth > 0 else { return chartRect.maxX }
        let viewportRightInContent = horizontalOffset + visibleWidth
        return min(max(viewportRightInContent, chartRect.minX), max(canvasWidth, chartRect.maxX))
    }

    private func fixedCueLabelX(chartRect: CGRect, canvasWidth: CGFloat) -> CGFloat {
        let guideEndX = fixedCueGuideEndX(chartRect: chartRect, canvasWidth: canvasWidth)
        return min(max(guideEndX - 8, chartRect.minX + 32), max(canvasWidth - 8, chartRect.minX + 32))
    }

    private func cueProfileLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 28 else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 27)
        return "\(trimmed[..<end])..."
    }

    private func formatTick(_ km: Double) -> String {
        if km < 1 {
            return String(format: "%.1f", km)
        }
        return String(format: "%.0f", km)
    }

    static func elevationBounds(trackPoints: [TrackPoint]) -> (minimum: Double, maximum: Double)? {
        let elevations = trackPoints.compactMap(\.ele)
        guard let maxEle = elevations.max() else { return nil }
        let roundedMaximum = max(100, ceil(max(0, maxEle) / 100) * 100)
        return (minimum: 0, maximum: roundedMaximum)
    }

    private static func elevationRangeMeters(trackPoints: [TrackPoint]) -> Double? {
        guard let bounds = elevationBounds(trackPoints: trackPoints) else { return nil }
        return bounds.maximum - bounds.minimum
    }
}

struct ElevationProfileHeaderView: View {
    let trackPoints: [TrackPoint]
    let width: CGFloat
    let contentWidth: CGFloat
    let visibleWidth: CGFloat
    let horizontalOffset: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                drawHeader(context: context, size: size)
            }
            .frame(width: width, height: ElevationProfileLayout.headerHeight)
            .offset(x: -horizontalOffset)
        }
        .frame(width: visibleWidth, height: ElevationProfileLayout.headerHeight, alignment: .topLeading)
        .clipped()
        .background(Color(.systemGroupedBackground))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func drawHeader(context: GraphicsContext, size: CGSize) {
        guard let bounds = ElevationProfileView.elevationBounds(trackPoints: trackPoints) else { return }

        let chartRect = CGRect(
            x: ElevationProfileLayout.leftPad,
            y: 0,
            width: max(1, contentWidth - ElevationProfileLayout.leftPad - ElevationProfileLayout.rightPad),
            height: size.height
        )

        func xPosition(_ elevation: Double) -> CGFloat {
            let ratio = CGFloat((elevation - bounds.minimum) / (bounds.maximum - bounds.minimum))
            return chartRect.minX + ratio * chartRect.width
        }

        var elevation = ceil(bounds.minimum / 100) * 100
        if elevation <= bounds.minimum + 0.001 {
            elevation += 100
        }

        while elevation < bounds.maximum - 0.001 {
            let x = xPosition(elevation)
            drawElevationLabel(
                formatRouteElevation(elevation),
                context: context,
                at: CGPoint(x: x, y: 6),
                anchor: .top,
                emphasized: false
            )
            elevation += 100
        }

        drawElevationLabel(
            formatRouteElevation(bounds.minimum),
            context: context,
            at: CGPoint(x: chartRect.minX, y: 6),
            anchor: .topLeading,
            emphasized: true
        )
        drawElevationLabel(
            formatRouteElevation(bounds.maximum),
            context: context,
            at: CGPoint(x: chartRect.maxX, y: 6),
            anchor: .topTrailing,
            emphasized: true
        )
    }

    private func drawElevationLabel(
        _ label: String,
        context: GraphicsContext,
        at point: CGPoint,
        anchor: UnitPoint,
        emphasized: Bool
    ) {
        context.draw(
            Text(label)
                .font(emphasized ? .caption2.weight(.semibold) : .caption2)
                .foregroundStyle(.secondary),
            at: point,
            anchor: anchor
        )
    }
}

private struct CueLabelPlacement {
    let cue: CourseCuePoint
    let guideY: CGFloat
    var labelY: CGFloat
}

private enum ElevationProfileLayout {
    static let leftPad: CGFloat = 44
    static let rightPad: CGFloat = 8
    static let topPad: CGFloat = 12
    static let bottomPad: CGFloat = 12
    static let emptyHeight: CGFloat = 160
    static let headerHeight: CGFloat = 28
    static let cueLabelGuideGap: CGFloat = 6
}
