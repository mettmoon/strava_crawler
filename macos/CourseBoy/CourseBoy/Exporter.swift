import Foundation
import AppKit
import UniformTypeIdentifiers

extension UTType {
    static var tcx: UTType { UTType(filenameExtension: "tcx") ?? .xml }
}

struct TCXExportOptions {
    var useNameAsNotes: Bool = false
}

/// 저장된 TCX 산출물을 사용자 선택 폴더에 파일로 내보낸다.
enum Exporter {
    @MainActor
    @discardableResult
    static func saveToFolder(prefix: String, cued: Data, rwgps: Data) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "저장"
        panel.message = "TCX 파일을 저장할 폴더를 선택하세요"
        guard panel.runModal() == .OK, let dir = panel.url else { return false }

        let cuedURL = dir.appendingPathComponent("\(prefix)_cued.tcx")
        let rwgpsURL = dir.appendingPathComponent("\(prefix)_cued_for_rwgps.tcx")
        do {
            try cued.write(to: cuedURL)
            try rwgps.write(to: rwgpsURL)
            NSWorkspace.shared.activateFileViewerSelecting([cuedURL, rwgpsURL])
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    @MainActor
    @discardableResult
    static func saveSingle(filename: String, data: Data) -> Bool {
        saveTCX(filename: filename, data: data)
    }

    @MainActor
    @discardableResult
    static func saveTCX(filename: String, data: Data) -> Bool {
        saveTCX(filename: filename) { _ in data }
    }

    /// TCX 저장 패널을 띄우고, 사용자가 선택한 옵션을 dataBuilder에 전달해 실제 데이터를 생성한다.
    /// dataBuilder가 nil을 반환하면 저장이 취소된다.
    @MainActor
    @discardableResult
    static func saveTCX(filename: String, dataBuilder: (TCXExportOptions) -> Data?) -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.tcx]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = sanitizedFilename(filename) + ".tcx"
        panel.prompt = "저장"
        panel.message = "TCX 파일로 저장할 위치를 선택하세요"

        let accessory = TCXExportAccessoryView()
        panel.accessoryView = accessory

        guard panel.runModal() == .OK, let url = panel.url else { return false }

        let options = accessory.options
        guard let data = dataBuilder(options) else {
            NSSound.beep()
            return false
        }

        do {
            try data.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    @MainActor
    @discardableResult
    static func saveSingleToFolder(filename: String, data: Data) -> Bool {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "저장"
        panel.message = "TCX 파일을 저장할 폴더를 선택하세요"
        guard panel.runModal() == .OK, let dir = panel.url else { return false }

        let url = dir.appendingPathComponent(filename + ".tcx")
        do {
            try data.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        } catch {
            NSSound.beep()
            return false
        }
    }

    private static func sanitizedFilename(_ filename: String) -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Course" : trimmed
        let invalid = CharacterSet(charactersIn: "/:")
        return base.components(separatedBy: invalid).joined(separator: "-")
    }
}

private final class TCXExportAccessoryView: NSView {
    private let nameAsNotesCheckbox: NSButton

    var options: TCXExportOptions {
        TCXExportOptions(useNameAsNotes: nameAsNotesCheckbox.state == .on)
    }

    init() {
        nameAsNotesCheckbox = NSButton(checkboxWithTitle: "메모의 내용을 name과 같게함", target: nil, action: nil)
        nameAsNotesCheckbox.translatesAutoresizingMaskIntoConstraints = false
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 40))
        addSubview(nameAsNotesCheckbox)
        NSLayoutConstraint.activate([
            nameAsNotesCheckbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            nameAsNotesCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            nameAsNotesCheckbox.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            nameAsNotesCheckbox.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
