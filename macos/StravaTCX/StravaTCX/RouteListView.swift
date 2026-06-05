import SwiftUI
import StravaTCXKit

struct RouteRow: View {
    @Environment(ImportCoordinator.self) private var coordinator
    let route: RouteRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(route.title)
                .fontWeight(.medium)
                .lineLimit(1)

            Group {
                switch route.status {
                case .processing:
                    let p = coordinator.progress(for: route)
                    HStack(spacing: 6) {
                        if let fraction = p?.fraction {
                            ProgressView(value: fraction).frame(maxWidth: 100)
                        } else {
                            ProgressView().controlSize(.mini)
                        }
                        Text(p?.message ?? "처리 중…").lineLimit(1)
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
