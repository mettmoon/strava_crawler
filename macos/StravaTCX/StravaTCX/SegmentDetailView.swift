import SwiftUI
import StravaTCXKit

struct SegmentDetailView: View {
    let segment: SegmentInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroImage
                titleBlock
                infoSection
                locationSection
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - 구성요소

    @ViewBuilder
    private var heroImage: some View {
        if let urlString = segment.imageURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                case .failure:
                    imagePlaceholder("photo")
                case .empty:
                    imagePlaceholder(nil)
                @unknown default:
                    EmptyView()
                }
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(segment.name)
                .font(.headline)
                .lineLimit(3)

            HStack(spacing: 8) {
                if let cat = segment.climbCategory {
                    Label(categoryLabel(cat), systemImage: "flag.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange, in: Capsule())
                }
                if let dist = segment.distanceText {
                    Text(dist).font(.caption).foregroundStyle(.secondary)
                }
                let g = Classification.gradeClass(segment.avgGrade)
                Text("\(g.arrow) \(segment.avgGrade ?? "—")")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let url = stravaURL {
                Link(destination: url) {
                    Label("스트라바에서 보기", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
            }
        }
    }

    private var infoSection: some View {
        Section {
            VStack(spacing: 0) {
                InfoDetailRow("카테고리", categoryLabel(segment.climbCategory))
                Divider().padding(.leading, 12)
                InfoDetailRow("거리", segment.distanceText ?? "—")
                Divider().padding(.leading, 12)
                InfoDetailRow("평균 경사", gradeText)
                Divider().padding(.leading, 12)
                InfoDetailRow("획득고도", segment.elevationGain ?? "—")
                Divider().padding(.leading, 12)
                InfoDetailRow("최저/최고", "\(segment.lowestElev ?? "—") / \(segment.highestElev ?? "—")")
                Divider().padding(.leading, 12)
                InfoDetailRow("고도차", segment.elevDifference ?? "—")
            }
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
        } header: {
            sectionHeader("정보", systemImage: "info.circle")
        }
    }

    private var locationSection: some View {
        Section {
            VStack(spacing: 0) {
                InfoDetailRow("Segment ID", segment.segmentID)
                Divider().padding(.leading, 12)
                InfoDetailRow("시작", pointText(segment.startPoint))
                Divider().padding(.leading, 12)
                InfoDetailRow("종료", pointText(segment.endPoint))
                if let url = googleMapsURL {
                    Divider().padding(.leading, 12)
                    HStack {
                        Spacer()
                        Link(destination: url) {
                            Label("구글맵에서 보기", systemImage: "map")
                                .font(.callout)
                        }
                        .padding(.trailing, 12)
                    }
                    .padding(.vertical, 7)
                }
            }
            .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 10))
        } header: {
            sectionHeader("위치", systemImage: "mappin.and.ellipse")
        }
    }

    // MARK: - 헬퍼

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
    }

    @ViewBuilder
    private func imagePlaceholder(_ icon: String?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(.fill.tertiary)
            if let icon {
                Image(systemName: icon).font(.largeTitle).foregroundStyle(.tertiary)
            } else {
                ProgressView()
            }
        }
        .frame(height: 160)
    }

    private var stravaURL: URL? {
        URL(string: "https://www.strava.com/segments/\(segment.segmentID)")
    }

    private var googleMapsURL: URL? {
        guard let p = segment.startPoint, p.count == 2 else { return nil }
        return URL(string: "https://www.google.com/maps/search/\(p[0]),\(p[1])")
    }

    private var gradeText: String {
        let g = Classification.gradeClass(segment.avgGrade)
        return "\(g.arrow) \(segment.avgGrade ?? "—")"
    }

    private func pointText(_ point: [Double]?) -> String {
        guard let p = point, p.count == 2 else { return "—" }
        return String(format: "%.5f, %.5f", p[0], p[1])
    }
}

// MARK: - InfoDetailRow

private struct InfoDetailRow: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
