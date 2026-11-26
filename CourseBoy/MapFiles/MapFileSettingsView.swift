import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CourseBoyMapFile

/// 설정의 '지도 파일' 탭. 지도 파일을 넣고 빼고, 노면 정보를 가져올 지도를 고른다.
struct MapFileSettingsView: View {
    private var store: MapFileStore { .shared }
    @State private var isImporting = false
    @State private var isAdding = false
    @State private var isDropTargeted = false
    @State private var errorMessage: String?

    var body: some View {
        @Bindable var store = store
        Form {
            Section {
                if store.files.isEmpty {
                    Text("추가한 지도 파일이 없습니다. 아래 버튼을 누르거나 .img 파일을 여기에 끌어 놓으세요.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.files) { file in
                    MapFileRow(
                        file: file,
                        showsOnMap: Binding(
                            get: { file.showsOnMap == true },
                            set: { store.setShowsOnMap($0, for: file) }
                        ),
                        onRemove: { store.remove(file) }
                    )
                }
                HStack {
                    Button {
                        isImporting = true
                    } label: {
                        Label("지도 파일 추가…", systemImage: "plus")
                    }
                    .disabled(isAdding)
                    if isAdding {
                        ProgressView().controlSize(.small)
                        Text("지도 파일 확인 중…")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("지도 파일")
            } footer: {
                Text("OpenStreetMap 기반 자전거 지도 같은 Garmin IMG 파일을 넣습니다. 파일은 앱으로 복사하지 않고 원래 위치에서 읽습니다. '지도에서 보기'를 켜면 지도 종류 메뉴의 오버레이에서 고를 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("노면 정보 소스", selection: $store.surfaceSourceID) {
                    Text("없음").tag(UUID?.none)
                    ForEach(store.files.filter(\.hasSurfaceInfo)) { file in
                        Text(file.name).tag(UUID?.some(file.id))
                    }
                }
            } header: {
                Text("노면 정보")
            } footer: {
                Text("고른 지도에서 도로별 포장 여부를 읽어 코스 인스펙터에 포장·비포장 비율을 보여주고, 지도(경로 색 '노면')와 고도 그래프에 비포장 구간을 점선으로 표시합니다. 경로 탐색 정보가 있는 지도만 노면 정보가 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        // .img는 시스템이 디스크 이미지로 보기도 해서 종류로 거르지 않고, 파일 머리글로 판별한다.
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data]) { result in
            guard case .success(let url) = result else { return }
            Task { await add(url) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            Task {
                for url in files { await add(url) }
            }
            return true
        } isTargeted: { isDropTargeted = $0 }
        .alert(
            "지도 파일을 추가하지 못했습니다",
            isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
        ) {
            Button("확인", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func add(_ url: URL) async {
        isAdding = true
        defer { isAdding = false }
        do {
            try await store.add(url)
        } catch let error as MapFileError {
            errorMessage = error.message
        } catch {
            errorMessage = MapFileError.unreadable.message
        }
    }
}

private struct MapFileRow: View {
    let file: MapFile
    @Binding var showsOnMap: Bool
    var onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .fontWeight(.medium)
                Text(verbatim: "\(file.fileName) · \(file.fileSize.formatted(.byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.sourcePath)
                Label(
                    file.hasSurfaceInfo ? "노면 정보 있음" : "노면 정보 없음",
                    systemImage: file.hasSurfaceInfo ? "checkmark.circle" : "minus.circle"
                )
                .font(.caption)
                .foregroundStyle(file.hasSurfaceInfo ? Color.green : Color.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Toggle("지도에서 보기", isOn: $showsOnMap)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Button("삭제", role: .destructive, action: onRemove)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Finder에서 보기") {
                NSWorkspace.shared.selectFile(file.sourcePath, inFileViewerRootedAtPath: "")
            }
            Button("삭제", role: .destructive, action: onRemove)
        }
    }
}
