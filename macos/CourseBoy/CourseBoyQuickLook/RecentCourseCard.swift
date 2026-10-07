import SwiftUI

/// 홈 화면의 최근 코스 카드. 위쪽 왼편에 형식·날짜·이름·거리, 오른편에 경로 썸네일을 두고,
/// 아래쪽에 고도 그래프를 카드 폭 가득 그린다.
struct RecentCourseCard: View {
    let course: RecentCourse
    var isMissing = false
    var isOpening = false

    static let cornerRadius: CGFloat = 22

    var body: some View {
        VStack(spacing: 10) {
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                RecentCourseThumbnail(course: course)
            }

            // 고도 데이터가 없는 파일은 빈 줄이 남지 않도록 그래프를 빼서 카드를 낮춘다.
            if course.elevationProfile.count >= 2 {
                ElevationSparkline(samples: course.elevationProfile)
                    .frame(height: 26)
            }
        }
        .foregroundStyle(HomePalette.ink)
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .fill(HomePalette.cardFill)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(HomePalette.cardStroke, lineWidth: 1.5)
        }
        .overlay {
            if isOpening {
                ProgressView()
                    .padding(10)
                    .background(.regularMaterial, in: Circle())
            }
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

/// 카드 아래쪽의 작은 고도 그래프. 샘플이 두 개 이상일 때만 카드에 넣는다.
struct ElevationSparkline: View {
    let samples: [Double]

    var body: some View {
        ZStack {
            SparklineShape(samples: samples, closed: true)
                .fill(HomePalette.ink.opacity(0.16))
            SparklineShape(samples: samples, closed: false)
                .stroke(HomePalette.ink.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .accessibilityHidden(true)
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

/// 카드 오른쪽 경로 썸네일. 격자 위에 저장해 둔 정사각형 경로 모양을 그린다.
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
            var route = Path()
            route.addLines(points)
            context.stroke(route, with: .color(HomePalette.ink), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
        .frame(width: Self.side, height: Self.side)
        .background(HomePalette.thumbnailFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityHidden(true)
    }
}
