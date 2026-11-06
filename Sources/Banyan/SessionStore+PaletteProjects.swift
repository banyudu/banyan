import BanyanCore
import Foundation

struct CommandPaletteProject: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let cwd: String
}

extension SessionStore {
    func rememberRecentProject(for session: BanyanSession, usedAt: Date) {
        guard !session.isImportedHistory, session.status != .closed else { return }
        recentProjectHistory.record(cwd: session.cwd, usedAt: usedAt)
    }

    /// Include live and recent projects independently of Focus, folded rows, and sidebar search.
    /// Resolve roots off the main actor once per palette opening, not on each keystroke.
    func commandPaletteProjects() async -> [CommandPaletteProject] {
        let active = visibleSessions.filter { !$0.isImportedHistory }
        let selected = active.first { $0.id == selectedSessionID }
        var seen = Set<String>()
        let candidates = active.compactMap { session -> CommandPaletteProject? in
            guard seen.insert(session.projectGroupID).inserted else { return nil }
            let representative = selected.flatMap { $0.projectGroupID == session.projectGroupID ? $0 : nil }
                ?? session
            return CommandPaletteProject(
                id: session.projectGroupID,
                title: session.projectGroupTitle,
                cwd: representative.cwd
            )
        }
        let environment = environment
        let live = await Task.detached(priority: .userInitiated) {
            candidates.map { project in
                CommandPaletteProject(
                    id: project.id,
                    title: project.title,
                    cwd: SessionDisplayLabel.workspaceRoot(cwd: project.cwd, environment: environment)
                )
            }
        }.value
        var paths = Set(live.map(\.cwd))
        let recent = await recentProjectHistory.projects().compactMap { project -> CommandPaletteProject? in
            guard seen.insert(project.id).inserted, paths.insert(project.cwd).inserted else { return nil }
            return CommandPaletteProject(id: project.id, title: project.title, cwd: project.cwd)
        }
        return live + recent
    }

    func projectCommandPaletteItems(for projects: [CommandPaletteProject]) -> [CommandPaletteItem] {
        projects.map { project in
            let launch = paletteAgentLaunch ?? projectLaunch(for: project.id)
            let path = project.cwd == homeDirectory ? "~"
                : project.cwd.hasPrefix(homeDirectory + "/")
                    ? "~" + String(project.cwd.dropFirst(homeDirectory.count)) : project.cwd
            return CommandPaletteItem(
                id: "session.new-project.\(project.id)",
                category: "Project",
                title: "New Session in \(project.title)",
                detail: "\(path) · \(launch.label)",
                shortcut: nil,
                action: { [weak self] in
                    _ = self?.spawnPaletteAgentSession(in: project, launch: launch)
                }
            )
        }
    }
}
