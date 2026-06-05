import Foundation
import AppKit

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
}
