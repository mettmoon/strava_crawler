import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class CourseShareViewModel: ObservableObject {
    let snapshot: CourseShareSnapshot

    @Published var options: CourseShareOptions
    @Published private(set) var previewImage: NSImage?
    @Published private(set) var isRenderingPreview = false
    @Published private(set) var isExporting = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var successMessage: String?

    private var previewTask: Task<Void, Never>?

    init(course: CourseRecord) {
        let snapshot = CourseShareSnapshot(course: course)
        self.snapshot = snapshot
        var options = CourseShareOptions()
        if !snapshot.hasElevation {
            options.outputMode = .mapOnly
        }
        self.options = options
    }

    deinit {
        previewTask?.cancel()
    }

    var canExport: Bool {
        options.isValid
            && snapshot.hasRoute
            && (!options.outputMode.includesElevation || snapshot.hasElevation)
            && !isExporting
    }

    func schedulePreview() {
        previewTask?.cancel()
        errorMessage = nil
        successMessage = nil
        isRenderingPreview = true
        let snapshot = snapshot
        let previewOptions = options.previewScaled()

        previewTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                let result = try await CourseShareRenderer.render(
                    snapshot: snapshot,
                    options: previewOptions
                )
                try Task.checkCancellation()
                self?.previewImage = result.previewImage
                self?.isRenderingPreview = false
            } catch is CancellationError {
                // A newer option change superseded this render.
            } catch {
                guard !Task.isCancelled else { return }
                self?.previewImage = nil
                self?.isRenderingPreview = false
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    func export() async {
        guard canExport else { return }
        previewTask?.cancel()
        isRenderingPreview = false
        isExporting = true
        errorMessage = nil
        successMessage = nil

        do {
            let result = try await CourseShareRenderer.render(
                snapshot: snapshot,
                options: options
            )
            guard let urls = try CourseShareImageExporter.save(
                artifacts: result.artifacts,
                courseTitle: snapshot.title
            ) else {
                isExporting = false
                schedulePreview()
                return
            }
            successMessage = urls.count == 1
                ? "이미지를 저장했습니다."
                : "이미지 \(urls.count)장을 저장했습니다."
        } catch {
            errorMessage = error.localizedDescription
        }
        isExporting = false
    }
}

@MainActor
struct CourseShareView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: CourseShareViewModel

    init(course: CourseRecord) {
        _model = StateObject(wrappedValue: CourseShareViewModel(course: course))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                previewPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                optionsPane
                    .frame(width: 340)
            }

            Divider()

            actionBar
        }
        .frame(minWidth: 1_020, minHeight: 700)
        .navigationTitle("공유 이미지 만들기")
        .onAppear {
            model.schedulePreview()
        }
        .onChange(of: model.options) {
            model.schedulePreview()
        }
    }

    private var previewPane: some View {
        ZStack {
            Color(nsColor: .underPageBackgroundColor)

            if let previewImage = model.previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(28)
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 5)
            } else if !model.isRenderingPreview {
                ContentUnavailableView {
                    Label("미리보기 없음", systemImage: "photo")
                } description: {
                    Text(model.errorMessage ?? "옵션을 조정하면 미리보기가 생성됩니다.")
                }
            }

            if model.isRenderingPreview || model.isExporting {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(model.isExporting ? "고해상도 이미지 생성 중…" : "미리보기 생성 중…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .accessibilityLabel("공유 이미지 미리보기")
    }

    private var optionsPane: some View {
        Form {
            Section("출력") {
                Picker("구성", selection: $model.options.outputMode) {
                    ForEach(CourseShareOutputMode.allCases) { mode in
                        Text(mode.label)
                            .tag(mode)
                            .disabled(mode.includesElevation && !model.snapshot.hasElevation)
                    }
                }
                .pickerStyle(.radioGroup)

                if model.options.outputMode == .combined {
                    Text("한 장으로 합칠 때 고도표 폭은 코스 이미지 폭에 맞춰집니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.options.outputMode.includesMap {
                Section {
                    Picker("지도", selection: $model.options.mapBackground) {
                        ForEach(CourseShareMapBackground.allCases) { background in
                            Text(background.label).tag(background)
                        }
                    }

                    if model.options.mapBackground == .solid {
                        ColorPicker(
                            "배경색",
                            selection: Binding(
                                get: { model.options.solidBackgroundColor.swiftUIColor },
                                set: { model.options.solidBackgroundColor = CourseShareColor(color: $0) }
                            ),
                            supportsOpacity: false
                        )
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("경로 두께")
                            Spacer()
                            Text("\(Int(model.options.routeLineWidth.rounded())) px")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(
                            value: $model.options.routeLineWidth,
                            in: 1 ... 24,
                            step: 1
                        )
                    }

                    Toggle(
                        "출발·도착지 표시",
                        isOn: $model.options.showsMapEndpoints
                    )
                    Toggle("웨이포인트 표시", isOn: $model.options.showsMapWaypoints)

                    CourseShareSizeEditor(
                        title: "이미지 크기",
                        size: $model.options.mapSize,
                        presets: CourseSharePixelSize.mapPresets,
                        locksWidth: false,
                        lockedWidth: nil
                    )
                } header: {
                    Text("코스")
                } footer: {
                    if model.options.mapBackground == .openStreetMap {
                        Text("OpenStreetMap 지도에는 라이선스 표시가 이미지에 포함됩니다.")
                    }
                }
            }

            if model.options.outputMode.includesElevation {
                Section("고도표") {
                    Toggle(
                        "웨이포인트 표시",
                        isOn: $model.options.showsElevationWaypoints
                    )
                    CourseShareSizeEditor(
                        title: "이미지 크기",
                        size: $model.options.elevationSize,
                        presets: CourseSharePixelSize.elevationPresets,
                        locksWidth: model.options.outputMode == .combined,
                        lockedWidth: model.options.outputMode == .combined
                            ? model.options.mapSize.width
                            : nil
                    )
                }
            }

            if !model.options.isValid {
                Section {
                    Label(
                        CourseShareError.invalidImageSize.localizedDescription,
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.red)
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Group {
                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if let successMessage = model.successMessage {
                    Label(successMessage, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .font(.callout)
            .lineLimit(2)

            Spacer()

            Button("취소") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            .disabled(model.isExporting)

            Button {
                Task { await model.export() }
            } label: {
                Text(model.isExporting ? "내보내는 중…" : "이미지 내보내기…")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canExport || model.isRenderingPreview)
        }
        .padding(16)
    }
}

private struct CourseShareSizeEditor: View {
    let title: String
    @Binding var size: CourseSharePixelSize
    let presets: [(label: String, size: CourseSharePixelSize)]
    let locksWidth: Bool
    let lockedWidth: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Menu("프리셋") {
                    ForEach(Array(presets.enumerated()), id: \.offset) { _, preset in
                        Button("\(preset.label) · \(preset.size.width)×\(preset.size.height)") {
                            size = preset.size
                        }
                    }
                }
                .menuStyle(.borderlessButton)
            }

            HStack(spacing: 8) {
                TextField(
                    "폭",
                    value: Binding(
                        get: { lockedWidth ?? size.width },
                        set: { if !locksWidth { size.width = $0 } }
                    ),
                    format: .number
                )
                .textFieldStyle(.roundedBorder)
                .disabled(locksWidth)

                Text("×")
                    .foregroundStyle(.secondary)

                TextField("높이", value: $size.height, format: .number)
                    .textFieldStyle(.roundedBorder)

                Text("px")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
private enum CourseShareImageExporter {
    static func save(
        artifacts: [CourseShareArtifact],
        courseTitle: String
    ) throws -> [URL]? {
        guard !artifacts.isEmpty else { throw CourseShareError.imageEncodingFailed }
        return artifacts.count == 1
            ? try saveSingle(artifacts[0], courseTitle: courseTitle)
            : try saveMultiple(artifacts, courseTitle: courseTitle)
    }

    private static func saveSingle(
        _ artifact: CourseShareArtifact,
        courseTitle: String
    ) throws -> [URL]? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = sanitizedFilename(courseTitle)
            + artifact.kind.filenameSuffix
            + ".png"
        panel.prompt = "내보내기"
        panel.message = "공유 이미지를 저장할 위치를 선택하세요."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            let data = try CourseShareImageEncoding.pngData(for: artifact.image)
            try data.write(to: url, options: .atomic)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return [url]
        } catch {
            throw CourseShareError.saveFailed(error.localizedDescription)
        }
    }

    private static func saveMultiple(
        _ artifacts: [CourseShareArtifact],
        courseTitle: String
    ) throws -> [URL]? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "내보내기"
        panel.message = "코스와 고도표 이미지를 저장할 폴더를 선택하세요."
        guard panel.runModal() == .OK, let directory = panel.url else { return nil }

        let baseName = sanitizedFilename(courseTitle)
        let destinations = artifacts.map { artifact in
            directory.appendingPathComponent(
                baseName + artifact.kind.filenameSuffix + ".png"
            )
        }
        if destinations.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            let alert = NSAlert()
            alert.messageText = "같은 이름의 파일이 이미 있습니다."
            alert.informativeText = "기존 파일을 덮어쓰시겠습니까?"
            alert.addButton(withTitle: "덮어쓰기")
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        }

        do {
            for (artifact, destination) in zip(artifacts, destinations) {
                let data = try CourseShareImageEncoding.pngData(for: artifact.image)
                try data.write(to: destination, options: .atomic)
            }
            NSWorkspace.shared.activateFileViewerSelecting(destinations)
            return destinations
        } catch {
            throw CourseShareError.saveFailed(error.localizedDescription)
        }
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Course" : trimmed
        let invalid = CharacterSet(charactersIn: "/:")
        return base.components(separatedBy: invalid).joined(separator: "-")
    }
}
