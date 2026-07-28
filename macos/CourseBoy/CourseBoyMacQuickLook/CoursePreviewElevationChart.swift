import CoursePreviewCore
import SwiftUI

struct CoursePreviewElevationChart: View {
    let trackPoints: [TrackPoint]

    private var elevatedPoints: [(distance: Double, elevation: Double)] {
        trackPoints.compactMap { point in
            point.ele.map { (point.cumKm, $0) }
        }
    }

    var body: some View {
        if elevatedPoints.count < 2 {
            ContentUnavailableView(
                "고도 데이터 없음",
                systemImage: "mountain.2",
                description: Text("파일에 표시할 고도 정보가 없습니다.")
            )
        } else {
            GeometryReader { proxy in
                let points = elevatedPoints
                let minElevation = points.map(\.elevation).min() ?? 0
                let maxElevation = points.map(\.elevation).max() ?? minElevation
                let maxDistance = max(points.last?.distance ?? 0, 0.001)
                let elevationSpan = max(maxElevation - minElevation, 1)

                ZStack(alignment: .bottomLeading) {
                    Path { path in
                        for (index, point) in points.enumerated() {
                            let x = proxy.size.width * point.distance / maxDistance
                            let y = proxy.size.height
                                * (1 - (point.elevation - minElevation) / elevationSpan)
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(.tint, style: StrokeStyle(lineWidth: 2, lineJoin: .round))

                    VStack {
                        HStack {
                            Text(formatRouteElevation(maxElevation))
                            Spacer()
                        }
                        Spacer()
                        HStack {
                            Text(formatRouteElevation(minElevation))
                            Spacer()
                            Text(formatRouteDistance(maxDistance))
                        }
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
