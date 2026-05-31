import SwiftUI
import SwiftData
import StravaTCXKit

/// ‘구간’ 탭 — 저장된 라우트들에서 다운로드한 세그먼트를 모아 보여준다.
/// 같은 세그먼트가 여러 라우트에 포함될 수 있으므로 segmentID 기준으로 중복 제거.
struct SegmentListView: View {
    @Query private var routes: [RouteRecord]

    private var segments: [SegmentInfo] {
        var seen = Set<String>()
        var result: [SegmentInfo] = []
        for route in routes {
            for seg in route.segments where seen.insert(seg.segmentID).inserted {
                result.append(seg)
            }
        }
        return result.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    @State private var selection: SegmentInfo?

    var body: some View {
        let segments = segments
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(segments) { segment in
                    SegmentRow(segment: segment)
                        .tag(segment)
                }
            }
            .navigationTitle("구간 (\(segments.count))")
            .frame(minWidth: 240)
            .overlay {
                if segments.isEmpty {
                    ContentUnavailableView(
                        "다운로드한 구간 없음",
                        systemImage: "mountain.2",
                        description: Text("‘경로’ 탭에서 라우트를 추가하면 포함된 구간이 여기에 모입니다.")
                    )
                }
            }
        } detail: {
            if let selection {
                SegmentDetailView(segment: selection)
            } else {
                ContentUnavailableView(
                    "구간을 선택하세요",
                    systemImage: "mountain.2",
                    description: Text("왼쪽 목록에서 구간을 고르면 상세 정보가 표시됩니다.")
                )
            }
        }
    }
}

/// 구간 목록 행 — 이름 + 카테고리/거리/경사 요약.
struct SegmentRow: View {
    let segment: SegmentInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(segment.name).fontWeight(.medium).lineLimit(1)
            HStack(spacing: 8) {
                if segment.climbCategory != nil {
                    Text(categoryLabel(segment.climbCategory))
                        .foregroundStyle(.orange)
                }
                Text(segment.distanceText ?? "—")
                let g = Classification.gradeClass(segment.avgGrade)
                Text("\(g.arrow) \(segment.avgGrade ?? "—")")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
