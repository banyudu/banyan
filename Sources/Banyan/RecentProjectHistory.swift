import BanyanCore
import Foundation

struct RecentProject: Codable, Equatable, Sendable {
    let id: String
    let title: String
    let cwd: String
    let lastUsedAt: Date
}

/// All mutable state and filesystem work stay on the store's persistence queue.
/// Recording use does not wait for git or SQLite on the main actor, and the
/// normal shutdown flush also drains pending project-history writes.
final class RecentProjectHistory: @unchecked Sendable {
    static let limit = 30
    private let queue: DispatchQueue
    private let persistence: any SessionStorePersistenceBackend
    private let environment: [String: String]
    private let homeDirectory: String
    private var entries: [RecentProject]?

    init(persistence: any SessionStorePersistenceBackend, queue: DispatchQueue,
         environment: [String: String], homeDirectory: String) {
        self.persistence = persistence
        self.queue = queue
        self.environment = environment
        self.homeDirectory = homeDirectory
        entries = persistence.loadRecentProjects()
    }

    func record(cwd: String, usedAt: Date) {
        queue.async { [self] in
            let root = SessionDisplayLabel.workspaceRoot(cwd: cwd, environment: environment)
            // OSC directory changes arrive before the session's async display
            // context. Resolve identity from the same path as the destination,
            // so a quick cd never overwrites the previous project's history.
            let context = SessionDisplayLabel.cachedContext(
                cwd: root, homeDirectory: homeDirectory, environment: environment)
            merge(RecentProject(id: context.groupID, title: context.groupTitle,
                cwd: root, lastUsedAt: usedAt))
        }
    }

    /// Upgrade existing installs from their retained sessions once. Closed rows
    /// deliberately have cheap path-only display labels, so resolve their real
    /// project identity here, off the main actor, stopping at 30 distinct projects.
    func seed(from snapshots: [SessionSnapshot]) {
        queue.async { [self] in
            guard entries == nil else { return }
            entries = []
            var seen = Set<String>()
            for snapshot in snapshots.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                guard seen.insert(snapshot.cwd).inserted, Self.isDirectory(snapshot.cwd) else { continue }
                let root = SessionDisplayLabel.workspaceRoot(cwd: snapshot.cwd, environment: environment)
                guard entries?.contains(where: { $0.cwd == root }) != true else { continue }
                let context = SessionDisplayLabel.cachedContext(
                    cwd: root, homeDirectory: homeDirectory, environment: environment)
                merge(RecentProject(id: context.groupID, title: context.groupTitle,
                    cwd: root, lastUsedAt: snapshot.updatedAt), persist: false)
                if entries?.count == Self.limit { break }
            }
            persistence.saveRecentProjects(entries ?? [])
        }
    }

    func projects() async -> [RecentProject] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                // Keep unavailable paths in storage: a temporarily unmounted
                // checkout can return, but should not offer a broken launch.
                continuation.resume(returning: (entries ?? []).filter { Self.isDirectory($0.cwd) })
            }
        }
    }

    private func merge(_ project: RecentProject, persist: Bool = true) {
        var next = entries ?? []
        if let existing = next.first(where: { $0.id == project.id || $0.cwd == project.cwd }),
           existing.lastUsedAt > project.lastUsedAt { return }
        next.removeAll { $0.id == project.id || $0.cwd == project.cwd }
        next.append(project)
        next.sort { $0.lastUsedAt > $1.lastUsedAt }
        next = Array(next.prefix(Self.limit))
        guard entries != next else { return }
        entries = next
        if persist { persistence.saveRecentProjects(next) }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
