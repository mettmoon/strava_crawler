import SwiftUI
import StravaTCXKit

/// 저장된(과거 캐시) 모든 구간을 보여주는 별도 윈도우.
/// "불러오기"를 누르면 구간 상세 워크스페이스 윈도우가 열린다.
struct SegmentLibraryView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var vm: SegmentLibraryViewModel

    init(vm: SegmentLibraryViewModel) {
        _vm = State(initialValue: vm)
    }

    var body: some View {
        @Bindable var bindableVM = vm
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("이름으로 검색", text: $bindableVM.searchText)
                    .textFieldStyle(.plain)
                if !vm.searchText.isEmpty {
                    Button {
                        vm.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(vm.filteredSegments.count)건")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()
            content
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 420, idealHeight: 600)
        .navigationTitle("구간 불러오기")
        .task { await vm.load() }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoading && vm.segments.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.segments.isEmpty {
            ContentUnavailableView {
                Label("저장된 구간 없음", systemImage: "mountain.2")
            } description: {
                Text("경로를 가져오면 구간이 자동으로 저장됩니다.")
            }
        } else if vm.filteredSegments.isEmpty {
            ContentUnavailableView.search(text: vm.searchText)
        } else {
            List {
                ForEach(vm.filteredSegments) { segment in
                    LibraryRow(segment: segment) {
                        openWindow(id: "segment-workspace", value: segment.segmentID)
                        dismissWindow(id: "segment-library")
                    }
                }
            }
        }
    }
}

private struct LibraryRow: View {
    let segment: SegmentInfo
    let onLoad: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SegmentRow(segment: segment)
            Spacer()
            Button("불러오기", action: onLoad)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}
