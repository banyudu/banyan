import AppKit
import Foundation

/// Requests user-granted access before a session starts a process in a folder
/// protected by macOS privacy controls (for example Documents or Desktop).
enum ProjectFolderAccess {
    static func requestIfNeeded(for path: String) -> Bool {
        let target = normalizedURL(for: path)
        guard !canReadDirectory(target) else { return true }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = nearestReadableParent(of: target)
        panel.message = "Banyan needs access to this project folder before starting its terminal."
        panel.prompt = "Allow Project Access"

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return false
        }

        let selected = normalizedURL(for: selectedURL.path)
        guard selected.path == target.path else {
            showWrongFolderAlert(target: target)
            return false
        }
        return canReadDirectory(target)
    }

    private static func normalizedURL(for path: String) -> URL {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private static func canReadDirectory(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private static func nearestReadableParent(of url: URL) -> URL {
        var candidate = url
        while !canReadDirectory(candidate), candidate.path != "/" {
            candidate.deleteLastPathComponent()
        }
        return candidate
    }

    private static func showWrongFolderAlert(target: URL) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Project folder not selected"
        alert.informativeText = "Select this exact folder to start the project:\n\n\(target.path)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
