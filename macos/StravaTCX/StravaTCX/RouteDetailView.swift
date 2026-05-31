import SwiftUI

/// 저장된 라우트 상세 — 요약 + 세그먼트 + CoursePoint + 파일 내보내기.
struct RouteDetailView: View {
    let record: RouteRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                summary
                segmentsSection
                coursePointsSection
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(.largeTitle.bold())
                Text(record.createdAt.formatted(date: .long, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Exporter.saveToFolder(
                    prefix: record.fileNamePrefix,
                    cued: record.cuedTCX,
                    rwgps: record.rwgpsTCX
                )
            } label: {
                Label("TCX 내보내기…", systemImage: "square.and.arrow.up")
            }
            .controlSize(.large)
        }
    }

    private var summary: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                InfoRow("Route ID", record.routeID)
                InfoRow("Trackpoint", "\(record.trackPointCount) 개")
                InfoRow("세그먼트", "\(record.segments.count) 개")
                InfoRow("최소 카테고리", record.minCategory.map(categoryLabel) ?? "전체")
                InfoRow("CoursePoint", "\(record.coursePointCount) 개")
            }
            .padding(8)
        } label: {
            Label("요약", systemImage: "doc.text")
        }
    }

    private var segmentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("세그먼트").font(.headline)
            Table(record.segments) {
                TableColumn("#") { s in Text(s.order.map(String.init) ?? "—") }
                    .width(28)
                TableColumn("이름") { s in Text(s.name) }
                TableColumn("카테고리") { s in
                    Text(categoryLabel(s.category))
                        .foregroundStyle(s.category == nil ? Color.secondary : Color.orange)
                }
                .width(80)
                TableColumn("거리") { s in Text(s.distance ?? "—") }.width(80)
                TableColumn("경사") { s in Text(s.grade ?? "—") }.width(70)
            }
            .frame(minHeight: 180)
        }
    }

    private var coursePointsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CoursePoint (\(record.coursePoints.count))").font(.headline)
            Table(record.coursePoints) {
                TableColumn("위치") { cp in
                    Text(cp.isStart ? "시작" : "종료")
                        .foregroundStyle(cp.isStart ? .primary : .secondary)
                }
                .width(48)
                TableColumn("PointType") { cp in
                    Text(cp.pointType).foregroundStyle(pointTypeColor(cp.pointType))
                }
                .width(130)
                TableColumn("Notes (RWGPS)") { cp in Text(cp.notes).monospaced() }
            }
            .frame(minHeight: 220)
        }
    }
}
