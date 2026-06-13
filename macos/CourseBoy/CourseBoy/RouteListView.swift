import SwiftUI
import CourseBoyKit

struct RouteRow: View {
    let route: Route
    let progress: ImportRouteUseCase.Progress?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(route.title)
                .fontWeight(.medium)
                .lineLimit(1)

            Group {
                switch route.status {
                case .processing:
                    HStack(spacing: 6) {
                        if let fraction = progress?.fraction {
                            ProgressView(value: fraction).frame(maxWidth: 100)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                        Text(progress?.message ?? "처리 중…").lineLimit(1)
                    }
                case .failed:
                    Label(route.errorMessage ?? "처리 실패", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                case .ready:
                    Text("\(route.coursePointCount) pts · \(route.createdAt.formatted(.relative(presentation: .named)))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
