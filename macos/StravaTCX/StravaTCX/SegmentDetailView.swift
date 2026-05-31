import SwiftUI
import StravaTCXKit

/// 구간 상세 — 선택한 세그먼트의 정보를 표시.
struct SegmentDetailView: View {
    let segment: SegmentInfo

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let urlString = segment.imageURL, let url = URL(string: urlString) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFit()
                        case .failure:
                            placeholder(systemImage: "photo")
                        case .empty:
                            placeholder(systemImage: nil)
                        @unknown default:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }

                Text(segment.name)
                    .font(.title2).fontWeight(.semibold)

                if let url = stravaURL {
                    Link(destination: url) {
                        Label("스트라바에서 보기", systemImage: "arrow.up.right.square")
                    }
                }

                GroupBox {
                    VStack(spacing: 6) {
                        InfoRow("카테고리", categoryLabel(segment.climbCategory))
                        InfoRow("거리", segment.distanceText ?? "—")
                        InfoRow("평균 경사", gradeText)
                        InfoRow("획득고도", segment.elevationGain ?? "—")
                        InfoRow("최저 고도", segment.lowestElev ?? "—")
                        InfoRow("최고 고도", segment.highestElev ?? "—")
                        InfoRow("고도차", segment.elevDifference ?? "—")
                    }
                    .padding(4)
                } label: {
                    Label("정보", systemImage: "info.circle")
                }

                GroupBox {
                    VStack(spacing: 6) {
                        InfoRow("Segment ID", segment.segmentID)
                        InfoRow("시작 지점", pointText(segment.startPoint))
                        InfoRow("종료 지점", pointText(segment.endPoint))
                        if let url = googleMapsURL {
                            HStack {
                                Spacer()
                                Link(destination: url) {
                                    Label("구글맵에서 보기", systemImage: "map")
                                }
                            }
                            .frame(maxWidth: 360)
                        }
                    }
                    .padding(4)
                } label: {
                    Label("위치", systemImage: "mappin.and.ellipse")
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(segment.name)
    }

    @ViewBuilder
    private func placeholder(systemImage: String?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let systemImage {
                Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(height: 200)
    }

    private var stravaURL: URL? {
        URL(string: "https://www.strava.com/segments/\(segment.segmentID)")
    }

    /// 구글맵 검색 URL — 시작 지점([lat, lng]) 기준.
    private var googleMapsURL: URL? {
        guard let p = segment.startPoint, p.count == 2 else { return nil }
        return URL(string: "https://www.google.com/maps/search/\(p[0]),\(p[1])")
    }

    private var gradeText: String {
        let g = Classification.gradeClass(segment.avgGrade)
        return "\(g.arrow) \(segment.avgGrade ?? "—")"
    }

    private func pointText(_ point: [Double]?) -> String {
        guard let point, point.count == 2 else { return "—" }
        return String(format: "%.5f, %.5f", point[0], point[1])
    }
}
