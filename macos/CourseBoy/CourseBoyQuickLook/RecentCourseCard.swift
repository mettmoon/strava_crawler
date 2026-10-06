import SwiftUI

/// 홈 화면의 최근 코스 카드. 왼쪽에 형식·날짜·이름·거리와 고도 그래프, 오른쪽에 지도 썸네일을 둔다.
struct RecentCourseCard: View {
    let course: RecentCourse
    var isMissing = false
    var isOpening = false

    static let cornerRadius: CGFloat = 22

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                metaRow

                Text(course.title)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(course.statsLabel)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()

                Spacer(minLength: 4)

                ElevationSparkline(samples: course.elevationProfile)
                    .frame(height: 26)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RecentCourseThumbnail(course: course)
                .overlay {
                    if isOpening {
                        ProgressView()
                            .padding(10)
                            .background(.regularMaterial, in: Circle())
                    }
                }
        }
        .foregroundStyle(HomePalette.ink)
        .padding(14)
        .frame(minHeight: 132)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(HomePalette.cardFill)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(HomePalette.cardStroke, lineWidth: 1.5)
        }
        .opacity(isMissing ? 0.5 : 1)
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint(isMissing ? "파일을 찾을 수 없음" : "코스를 엽니다")
    }

    @ViewBuilder
    private var metaRow: some View {
        HStack(spacing: 4) {
            if isMissing {
                Image(systemName: "exclamationmark.triangle")
                Text("파일을 찾을 수 없음")
            } else {
                Image(systemName: "doc")
                Text("\(course.fileKind) · \(course.lastOpenedLabel)")
            }
            if course.isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .accessibilityLabel("즐겨찾기")
            }
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
    }
}

/// 카드 아래쪽의 작은 고도 그래프. 고도 데이터가 없으면 자리만 차지한다.
struct ElevationSparkline: View {
    let samples: [Double]

    var body: some View {
        if samples.count >= 2 {
            ZStack {
                SparklineShape(samples: samples, closed: true)
                    .fill(HomePalette.ink.opacity(0.16))
                SparklineShape(samples: samples, closed: false)
                    .stroke(HomePalette.ink.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
            .accessibilityHidden(true)
        } else {
            Color.clear
        }
    }
}

private struct SparklineShape: Shape {
    let samples: [Double]
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        guard let minValue = samples.min(), let maxValue = samples.max() else { return Path() }
        // 평지 코스가 과장돼 보이지 않도록 고도 차가 작으면 최소 60m 폭으로 그린다.
        let span = max(maxValue - minValue, 60)
        let base = minValue - (span - (maxValue - minValue)) / 2
        let step = rect.width / CGFloat(samples.count - 1)
        let inset: CGFloat = 1.5

        var path = Path()
        for (index, value) in samples.enumerated() {
            let ratio = CGFloat((value - base) / span)
            let point = CGPoint(
                x: rect.minX + CGFloat(index) * step,
                y: rect.maxY - inset - ratio * (rect.height - inset * 2)
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        if closed {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

/// 카드 오른쪽 경로 썸네일. 격자 위에 저장해 둔 정사각형 경로 모양과 시작점을 그린다.
struct RecentCourseThumbnail: View {
    let course: RecentCourse

    static let side: CGFloat = 104
    private static let inset: CGFloat = 14

    var body: some View {
        Canvas { context, size in
            let grid = Path { path in
                for fraction in [0.25, 0.5, 0.75] {
                    path.move(to: CGPoint(x: size.width * fraction, y: 0))
                    path.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
                    path.move(to: CGPoint(x: 0, y: size.height * fraction))
                    path.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
                }
            }
            context.stroke(grid, with: .color(HomePalette.thumbnailGrid), lineWidth: 1)

            let length = min(size.width, size.height) - Self.inset * 2
            let points = course.routeShape.map { point in
                CGPoint(x: Self.inset + point.x * length, y: Self.inset + point.y * length)
            }
            guard let start = points.first else { return }
            var route = Path()
            route.addLines(points)
            context.stroke(route, with: .color(HomePalette.ink), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))

            let marker = Path(ellipseIn: CGRect(x: start.x - 6, y: start.y - 6, width: 12, height: 12))
            context.fill(marker, with: .color(.white))
            context.stroke(marker, with: .color(HomePalette.ink), lineWidth: 2.5)
        }
        .frame(width: Self.side, height: Self.side)
        .background(HomePalette.thumbnailFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }
}
