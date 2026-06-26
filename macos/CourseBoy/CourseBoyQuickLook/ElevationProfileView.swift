import SwiftUI

struct ElevationProfileView: View {
    let trackPoints: [TrackPoint]
    let cuePoints: [CourseCuePoint]
    let selectedCueID: UUID?

    private var elevationPoints: [TrackPoint] {
        trackPoints.filter { $0.ele != nil }
    }

    var body: some View {
        if elevationPoints.count < 2 {
            ContentUnavailableView {
                Label("고도 데이터 없음", systemImage: "mountain.2")
            } description: {
                Text("이 파일에는 표시할 고도값이 없습니다.")
            }
            .frame(maxWidth: .infinity, minHeight: 160)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        } else {
            Canvas { context, size in
                drawProfile(context: context, size: size)
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func drawProfile(context: GraphicsContext, size: CGSize) {
        let leftPad: CGFloat = 44
        let rightPad: CGFloat = 12
        let topPad: CGFloat = 14
        let bottomPad: CGFloat = 28
        let chartRect = CGRect(
            x: leftPad,
            y: topPad,
            width: max(1, size.width - leftPad - rightPad),
            height: max(1, size.height - topPad - bottomPad)
        )

        let elevations = elevationPoints.compactMap(\.ele)
        guard let minEle = elevations.min(),
              let maxEle = elevations.max(),
              maxEle > minEle else { return }

        let totalKm = max(trackPoints.last?.cumKm ?? 0, 0.001)

        func xPosition(_ km: Double) -> CGFloat {
            chartRect.minX + CGFloat(km / totalKm) * chartRect.width
        }

        func yPosition(_ ele: Double) -> CGFloat {
            let ratio = CGFloat((ele - minEle) / (maxEle - minEle))
            return chartRect.maxY - ratio * chartRect.height
        }

        drawGrid(context: context, chartRect: chartRect, totalKm: totalKm, minEle: minEle, maxEle: maxEle)

        let points = elevationPoints.compactMap { point -> CGPoint? in
            guard let ele = point.ele else { return nil }
            return CGPoint(x: xPosition(point.cumKm), y: yPosition(ele))
        }
        guard let firstPoint = points.first, let lastPoint = points.last else { return }

        var fill = Path()
        fill.move(to: CGPoint(x: firstPoint.x, y: chartRect.maxY))
        for point in points {
            fill.addLine(to: point)
        }
        fill.addLine(to: CGPoint(x: lastPoint.x, y: chartRect.maxY))
        fill.closeSubpath()

        context.fill(
            fill,
            with: .linearGradient(
                Gradient(colors: [Color.orange.opacity(0.42), Color.orange.opacity(0.10)]),
                startPoint: CGPoint(x: 0, y: chartRect.minY),
                endPoint: CGPoint(x: 0, y: chartRect.maxY)
            )
        )

        var line = Path()
        line.move(to: firstPoint)
        for point in points.dropFirst() {
            line.addLine(to: point)
        }
        context.stroke(line, with: .color(.orange), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

        for cue in cuePoints {
            let selected = cue.id == selectedCueID
            let glyph = cuePointGlyph(for: cue.pointType)
            let x = xPosition(cue.distanceKm)
            var marker = Path()
            marker.move(to: CGPoint(x: x, y: chartRect.minY))
            marker.addLine(to: CGPoint(x: x, y: chartRect.maxY))
            context.stroke(
                marker,
                with: .color(selected ? glyph.color : glyph.color.opacity(0.45)),
                style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: selected ? [] : [4, 3])
            )

            if selected {
                let label = cue.displayName
                context.draw(
                    Text(label).font(.caption2.weight(.semibold)).foregroundStyle(glyph.color),
                    at: CGPoint(x: min(max(x, chartRect.minX + 4), chartRect.maxX - 4), y: chartRect.minY + 2),
                    anchor: x < chartRect.midX ? .topLeading : .topTrailing
                )
            }
        }

        context.draw(
            Text(formatRouteElevation(maxEle)).font(.caption2).foregroundStyle(.secondary),
            at: CGPoint(x: 8, y: chartRect.minY),
            anchor: .topLeading
        )
        context.draw(
            Text(formatRouteElevation(minEle)).font(.caption2).foregroundStyle(.secondary),
            at: CGPoint(x: 8, y: chartRect.maxY),
            anchor: .bottomLeading
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

        let horizontalLines = 3
        for index in 1..<horizontalLines {
            let y = chartRect.minY + chartRect.height * CGFloat(index) / CGFloat(horizontalLines)
            var path = Path()
            path.move(to: CGPoint(x: chartRect.minX, y: y))
            path.addLine(to: CGPoint(x: chartRect.maxX, y: y))
            context.stroke(path, with: .color(.secondary.opacity(0.14)), lineWidth: 0.5)
        }

        let tickInterval = distanceTickInterval(totalKm: totalKm, width: chartRect.width)
        var km = 0.0
        while km <= totalKm + tickInterval * 0.1 {
            let x = chartRect.minX + CGFloat(km / totalKm) * chartRect.width
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: chartRect.maxY))
            tick.addLine(to: CGPoint(x: x, y: chartRect.maxY + 5))
            context.stroke(tick, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
            context.draw(
                Text(formatTick(km)).font(.caption2).foregroundStyle(.secondary),
                at: CGPoint(x: x, y: chartRect.maxY + 8),
                anchor: .top
            )
            km += tickInterval
        }
    }

    private func distanceTickInterval(totalKm: Double, width: CGFloat) -> Double {
        let candidates = [0.5, 1, 2, 5, 10, 20, 25, 50, 100, 200]
        let minTickWidth = 56.0
        return candidates.first { $0 / max(totalKm, 0.001) * Double(width) >= minTickWidth } ?? 200
    }

    private func formatTick(_ km: Double) -> String {
        if km < 1 {
            return String(format: "%.1f", km)
        }
        return String(format: "%.0f", km)
    }
}
