import BanyanCore
import Foundation

struct CommandPaletteProject: Identifiable, Sendable {
    let id: String
    let title: String
    let cwd: String
}

extension SessionStore {
    /// Snapshot live projects independently of Focus, folded rows, and sidebar search.
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
        return await Task.detached(priority: .userInitiated) {
            candidates.map { project in
                CommandPaletteProject(
                    id: project.id,
                    title: project.title,
                    cwd: SessionDisplayLabel.workspaceRoot(cwd: project.cwd, environment: environment)
                )
            }
        }.value
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
