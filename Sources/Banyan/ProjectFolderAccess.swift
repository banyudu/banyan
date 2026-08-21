import AppKit
import Foundation

/// Requests user-granted access before a session starts a process in a folder
/// protected by macOS privacy controls (for example Documents or Desktop).
enum ProjectFolderAccess {
    enum Result: Equatable {
        case available
        case missingFolder
        case permissionDenied
    }

    private static let bookmarkDefaultsKey = "project-folder-security-scoped-bookmarks"
    private static var activeBookmarkPaths = Set<String>()

    static func evaluate(for path: String) -> Result {
        let target = normalizedURL(for: path)
        guard FileManager.default.fileExists(atPath: target.path) else {
            return .missingFolder
        }
        restoreBookmarkAccess(for: target)
        return canReadDirectory(target) ? .available : .permissionDenied
    }

    static func requestIfNeeded(for path: String) -> Bool {
        let target = normalizedURL(for: path)
        switch evaluate(for: path) {
        case .available:
            return true
        case .missingFolder:
            return false
        case .permissionDenied:
            break
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = nearestReadableParent(of: target)
        panel.message = "Banyan needs access to this project folder (or its parent) before starting its terminal."
        panel.prompt = "Allow Project Access"

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return false
        }

        let selected = normalizedURL(for: selectedURL.path)
        guard isAncestorOrSame(selected, as: target) else {
            showWrongFolderAlert(target: target)
            return false
        }
        persistBookmark(for: selected)
        return canReadDirectory(target)
    }

    private static func normalizedURL(for path: String) -> URL {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private static func canReadDirectory(_ url: URL) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
            return true
        } catch {
            return false
        }
    }

    private static func isAncestorOrSame(_ ancestor: URL, as descendant: URL) -> Bool {
        let ancestorPath = ancestor.path.hasSuffix("/") ? ancestor.path : ancestor.path + "/"
        return descendant.path == ancestor.path || descendant.path.hasPrefix(ancestorPath)
    }

    private static func persistBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(options: .withSecurityScope,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil) else {
            return
        }
        var bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkDefaultsKey) as? [String: Data] ?? [:]
        bookmarks[url.path] = data
        UserDefaults.standard.set(bookmarks, forKey: bookmarkDefaultsKey)
        _ = url.startAccessingSecurityScopedResource()
        activeBookmarkPaths.insert(url.path)
    }

    private static func restoreBookmarkAccess(for target: URL) {
        let bookmarks = UserDefaults.standard.dictionary(forKey: bookmarkDefaultsKey) as? [String: Data] ?? [:]
        for (path, data) in bookmarks {
            var isStale = false
            guard !activeBookmarkPaths.contains(path),
                  let url = try? URL(resolvingBookmarkData: data,
                                     options: .withSecurityScope,
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &isStale),
                  isAncestorOrSame(url, as: target),
                  url.startAccessingSecurityScopedResource() else {
                continue
            }
            activeBookmarkPaths.insert(path)
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
