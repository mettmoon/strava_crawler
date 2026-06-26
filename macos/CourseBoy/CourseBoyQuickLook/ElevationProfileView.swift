import SwiftUI

struct ElevationProfileScale: Equatable {
    var distanceFactor: CGFloat
    var elevationFactor: CGFloat

    static let standard = ElevationProfileScale(distanceFactor: 1, elevationFactor: 1)
}

struct ElevationProfileView: View {
    let trackPoints: [TrackPoint]
    let cuePoints: [CourseCuePoint]
    let selectedCueID: UUID?

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
        let chartWidth = baseChartWidth * max(0.25, scale.elevationFactor)
        let pixelsPerKm = baseChartWidth / CGFloat(max(1, elevationRange) / 100)
        let chartHeight = max(
            1,
            CGFloat(max(trackPoints.last?.cumKm ?? 0, 0)) * pixelsPerKm * max(0.25, scale.distanceFactor)
        )

        return CGSize(
            width: chartWidth + ElevationProfileLayout.leftPad + ElevationProfileLayout.rightPad,
            height: max(
                ElevationProfileLayout.emptyHeight,
                chartHeight + ElevationProfileLayout.topPad + ElevationProfileLayout.bottomPad
            )
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
            Canvas { context, size in
                drawProfile(context: context, size: size)
            }
        }
    }

    private func drawProfile(context: GraphicsContext, size: CGSize) {
        let chartRect = CGRect(
            x: ElevationProfileLayout.leftPad,
            y: ElevationProfileLayout.topPad,
            width: max(1, size.width - ElevationProfileLayout.leftPad - ElevationProfileLayout.rightPad),
            height: max(1, size.height - ElevationProfileLayout.topPad - ElevationProfileLayout.bottomPad)
        )

        let elevations = elevationPoints.compactMap(\.ele)
        guard let minEle = elevations.min(),
              let maxEle = elevations.max(),
              maxEle > minEle else { return }

        let totalKm = max(trackPoints.last?.cumKm ?? 0, 0.001)

        func xPosition(_ ele: Double) -> CGFloat {
            let ratio = CGFloat((ele - minEle) / (maxEle - minEle))
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

        for placement in cuePlacements {
            let cue = placement.cue
            let selected = cue.id == selectedCueID
            let glyph = cuePointGlyph(for: cue.pointType)
            let y = placement.guideY
            var marker = Path()
            marker.move(to: CGPoint(x: chartRect.minX, y: y))
            marker.addLine(to: CGPoint(x: chartRect.maxX, y: y))
            context.stroke(
                marker,
                with: .color(selected ? glyph.color : glyph.color.opacity(0.45)),
                style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [4, 3])
            )
        }

        for placement in cuePlacements where placement.cue.id != selectedCueID {
            drawCueLabel(placement, context: context, chartRect: chartRect, selected: false)
        }

        if let selectedPlacement = cuePlacements.first(where: { $0.cue.id == selectedCueID }) {
            drawCueLabel(selectedPlacement, context: context, chartRect: chartRect, selected: true)
        }

        context.draw(
            Text(formatRouteElevation(minEle)).font(.caption2).foregroundStyle(.secondary),
            at: CGPoint(x: chartRect.minX, y: chartRect.maxY + 18),
            anchor: .topLeading
        )
        context.draw(
            Text(formatRouteElevation(maxEle)).font(.caption2).foregroundStyle(.secondary),
            at: CGPoint(x: chartRect.maxX, y: chartRect.maxY + 18),
            anchor: .topTrailing
        )
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

        let elevationLines = 3
        for index in 1..<elevationLines {
            let x = chartRect.minX + chartRect.width * CGFloat(index) / CGFloat(elevationLines)
            var path = Path()
            path.move(to: CGPoint(x: x, y: chartRect.minY))
            path.addLine(to: CGPoint(x: x, y: chartRect.maxY))
            context.stroke(path, with: .color(.secondary.opacity(0.14)), lineWidth: 0.5)
        }

        let tickInterval = distanceTickInterval(totalKm: totalKm, length: chartRect.height)
        var km = 0.0
        while km <= totalKm + tickInterval * 0.1 {
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
            km += tickInterval
        }

        let midEle = (minEle + maxEle) / 2
        context.draw(
            Text(formatRouteElevation(midEle)).font(.caption2).foregroundStyle(.secondary),
            at: CGPoint(x: chartRect.midX, y: chartRect.maxY + 18),
            anchor: .top
        )
    }

    private func distanceTickInterval(totalKm: Double, length: CGFloat) -> Double {
        let candidates = [0.5, 1, 2, 5, 10, 20, 25, 50, 100, 200]
        let minTickLength = 58.0
        return candidates.first { $0 / max(totalKm, 0.001) * Double(length) >= minTickLength } ?? 200
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
        chartRect: CGRect,
        selected: Bool
    ) {
        let cue = placement.cue
        let glyph = cuePointGlyph(for: cue.pointType)
        let color = selected ? glyph.color : glyph.color.opacity(0.86)
        let label = cueProfileLabel(cue.displayName)
        let weight: Font.Weight = selected ? .bold : .semibold

        context.draw(
            Text(label).font(.caption2.weight(weight)).foregroundStyle(color),
            at: CGPoint(x: chartRect.maxX - 4, y: placement.labelY),
            anchor: .trailing
        )
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

    private static func elevationRangeMeters(trackPoints: [TrackPoint]) -> Double? {
        let elevations = trackPoints.compactMap(\.ele)
        guard let minEle = elevations.min(),
              let maxEle = elevations.max(),
              maxEle > minEle else { return nil }
        return maxEle - minEle
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
    static let bottomPad: CGFloat = 34
    static let emptyHeight: CGFloat = 160
}
