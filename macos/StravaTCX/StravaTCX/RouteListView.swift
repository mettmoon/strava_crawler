import SwiftUI
import SwiftData

/// 앱 첫 화면 — 저장된 라우트 목록 + ‘추가하기’.
struct RouteListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \RouteRecord.createdAt, order: .reverse) private var routes: [RouteRecord]
    @State private var selection: RouteRecord?
    @State private var showingAdd = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(routes) { route in
                    RouteRow(route: route).tag(route)
                }
                .onDelete(perform: delete)
            }
            .navigationTitle("라우트")
            .frame(minWidth: 240)
            .overlay {
                if routes.isEmpty {
                    ContentUnavailableView(
                        "저장된 라우트 없음",
                        systemImage: "tray",
                        description: Text("‘추가하기’ 로 첫 라우트를 변환하세요.")
                    )
                }
            }
            .toolbar {
                ToolbarItem {
                    Button { showingAdd = true } label: {
                        Label("추가하기", systemImage: "plus")
                    }
                }
            }
        } detail: {
            if let selection {
                RouteDetailView(record: selection)
            } else {
                ContentUnavailableView(
                    "라우트를 선택하세요",
                    systemImage: "bicycle",
                    description: Text("왼쪽 목록에서 라우트를 고르거나 ‘추가하기’ 로 새로 변환하세요.")
                )
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddRouteView { record in
                context.insert(record)
                selection = record
            }
        }
    }

    private func delete(_ offsets: IndexSet) {
        for index in offsets {
            context.delete(routes[index])
        }
    }
}

struct RouteRow: View {
    let route: RouteRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(route.title).fontWeight(.medium).lineLimit(1)
            Text("\(route.coursePointCount) CoursePoint · \(route.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
