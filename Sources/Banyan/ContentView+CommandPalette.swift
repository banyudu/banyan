import AppKit
import BanyanCore
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension ContentView {
    func dismissCommandPalette() {
        showingCommandPalette = false
        store.focusSelectedTerminal()
    }

    /// Resolves a Linear issue id to the URL this host opens it at, honoring a
    /// configured base URL or org. Shared by the command palette and the sidebar
    /// suggestion banner so an issue id means the same destination wherever it
    /// is clicked.
    func linearIssueURL(_ issueID: String) -> URL? {
        URL(string: LinearIssueReference.issueURL(
            for: issueID,
            environment: store.host.environment
        ))
    }

    /// Opens a Linear issue in the browser.
    func openLinearIssue(_ issueID: String) {
        guard let url = linearIssueURL(issueID) else { return }
        NSWorkspace.shared.open(url)
    }

    var commandPaletteItems: [CommandPaletteItem] {
        var items = [
            CommandPaletteItem(
                id: "session.new",
                category: "Session",
                title: "New Session",
                detail: store.paletteAgentLaunch.map { "New \($0.label) session" } ?? "Create a sibling session",
                shortcut: "⌘N",
                action: { _ = store.spawnPaletteAgentSession() }
            ),
            CommandPaletteItem(
                id: "session.new-project",
                category: "Session",
                title: "New Session in Project Root",
                detail: store.paletteAgentLaunch.map {
                    "Open \($0.label) at the project root"
                } ?? "Open a session at the project root",
                shortcut: nil,
                action: { _ = store.spawnPaletteAgentSessionInProjectRoot() }
            ),
            CommandPaletteItem(
                id: "terminal.new",
                category: "Terminal",
                title: "New Terminal",
                detail: "Create a terminal sibling",
                shortcut: "⌘⇧N",
                action: { _ = store.spawnTerminalSiblingSession() }
            ),
            CommandPaletteItem(
                id: "terminal.scratch",
                category: "Terminal",
                title: "Open Scratch Terminal",
                detail: "Open a temporary terminal window",
                shortcut: "⌘D",
                action: store.openScratchTerminal
            ),
            CommandPaletteItem(
                id: "terminal.find",
                category: "Terminal",
                title: "Find",
                detail: "Search the current terminal or Linear issues",
                shortcut: "⌘F",
                action: {
                    if store.sidebarMode == .linear {
                        store.requestLinearFilterFocus()
                    } else {
                        store.showFindInSelectedSession()
                    }
                }
            ),
            CommandPaletteItem(
                id: "session.rename",
                category: "Session",
                title: "Rename Session",
                detail: store.selectedSession?.displayTitle,
                shortcut: "F2",
                action: store.selection.requestRenameSelectedSession
            ),
            CommandPaletteItem(
                id: "terminal.close",
                category: "Terminal",
                title: "Close Current Terminal",
                detail: store.selectedSession?.displayTitle,
                shortcut: "⌘W",
                action: { store.handleCloseCommand(in: NSApp.keyWindow) }
            ),
            CommandPaletteItem(
                id: "linear.show",
                category: "Linear",
                title: "Show Linear Issues",
                detail: "Open the Linear sidebar",
                shortcut: "⌘⇧L",
                action: { store.sidebarMode = .linear }
            ),
            CommandPaletteItem(
                id: "linear.refresh",
                category: "Linear",
                title: "Refresh Linear Issues",
                detail: nil,
                shortcut: nil,
                action: store.refreshLinearIssueList
            ),
            CommandPaletteItem(
                id: "linear.open-selected",
                category: "Linear",
                title: "Open Selected Linear Issue",
                detail: store.selectedLinearIssueURL?.absoluteString,
                shortcut: "⌘L",
                action: store.openSelectedLinearIssue
            ),
            CommandPaletteItem(
                id: "linear.start-selected",
                category: "Linear",
                title: "Start Selected Linear Issue",
                detail: store.selectedLinearListIssueID,
                shortcut: "⌘↩",
                action: store.startSelectedLinearListIssueSession
            ),
            CommandPaletteItem(
                id: "github.preview-selected",
                category: "GitHub",
                title: "Preview Selected Pull Request",
                detail: store.selectedPullRequestURL?.absoluteString,
                shortcut: nil,
                action: store.showSelectedPullRequestPreview
            ),
            CommandPaletteItem(
                id: "github.open-selected",
                category: "GitHub",
                title: "Open Selected Pull Request in Browser",
                detail: store.selectedPullRequestURL?.absoluteString,
                shortcut: "⌘G",
                action: store.openSelectedPullRequest
            )
        ]

        items.append(contentsOf: NavigationCommandPaletteItems.items(
            onNextSession: store.selectNextSession,
            onPreviousSession: store.selectPreviousSession,
            onNextNeedingAttention: store.selectNextSessionNeedingAttention,
            onPreviousNeedingAttention: store.selectPreviousSessionNeedingAttention,
            onNextWorkable: store.selectNextWorkableSession
        ))

        items.append(CommandPaletteItem(
            id: "view.sessions",
            category: "View",
            title: "Show Sessions",
            detail: "Open the sessions sidebar",
            shortcut: "⌘⇧S",
            action: { store.sidebarMode = .sessions }
        ))

        items.append(contentsOf: ViewCommandPaletteItems.items(
            sidebarScope: store.sidebarScope,
            onToggleFocusMode: {
                store.sidebarScope = store.sidebarScope.toggled
            }
        ))

        let fallbackTarget = paletteFallbackTarget
        for paletteCommand in store.paletteCommands {
            let title = paletteCommand.expandedTitle(
                target: fallbackTarget,
                query: nil,
                agent: store.paletteAgentLaunch?.id
            )
            let detail = paletteCommand.expandedCommand(
                target: fallbackTarget,
                query: nil,
                agent: store.paletteAgentLaunch?.id
            )
            items.append(CommandPaletteItem(
                id: "custom.\(paletteCommand.id)",
                category: "Custom",
                title: title,
                detail: detail.isEmpty ? nil : detail,
                shortcut: nil,
                action: { [weak store = store] in
                    store?.runPaletteCommand(paletteCommand, target: fallbackTarget, query: nil)
                }
            ))
        }

        items.append(contentsOf: store.projectCommandPaletteItems(for: commandPaletteProjects))

        for item in store.sidebarSessions {
            let shortcut = sessionJumpShortcuts.shortcutDisplay(for: item.id)
            items.append(CommandPaletteItem(
                id: "session.switch.\(item.id)",
                category: "Session",
                title: "Switch to \(item.session.displayTitle)",
                detail: item.session.cwd,
                shortcut: shortcut,
                action: { store.select(id: item.id) }
            ))
        }

        return items
    }

    /// Target used for static custom-command rows: the selected Linear issue,
    /// else a Linear ID detected in the selected session's title.
    private var paletteFallbackTarget: String? {
        if let issueID = store.selectedLinearListIssueID {
            return issueID
        }
        return LinearIssueReference.issueID(in: store.selectedSession?.displayTitle)
    }
}
