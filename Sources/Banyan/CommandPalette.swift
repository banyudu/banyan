import AppKit
import BanyanCore
import SwiftUI

struct CommandPaletteItem: Identifiable {
    let id: String
    let category: String
    let title: String
    let detail: String?
    let shortcut: String?
    let action: () -> Void
}

/// The Navigation rows of the command palette.
///
/// Built here rather than inline in `ContentView` so the advertised shortcut
/// labels come from `SessionAttentionShortcuts` — the same values the key
/// monitor matches and the menu binds — and so they can be asserted in tests.
enum NavigationCommandPaletteItems {
    static func items(
        onNextSession: @escaping () -> Void,
        onPreviousSession: @escaping () -> Void,
        onNextNeedingAttention: @escaping () -> Void,
        onPreviousNeedingAttention: @escaping () -> Void,
        onNextWorkable: @escaping () -> Void
    ) -> [CommandPaletteItem] {
        [
            CommandPaletteItem(
                id: "navigation.next-session",
                category: "Navigation",
                title: "Next Session",
                detail: nil,
                shortcut: "⌘J",
                action: onNextSession
            ),
            CommandPaletteItem(
                id: "navigation.previous-session",
                category: "Navigation",
                title: "Previous Session",
                detail: nil,
                shortcut: "⌘K",
                action: onPreviousSession
            ),
            CommandPaletteItem(
                id: "navigation.next-needs-attention",
                category: "Navigation",
                title: "Next Session Needing Attention",
                detail: "Jump to a session waiting on a decision",
                shortcut: SessionAttentionShortcuts.next.display,
                action: onNextNeedingAttention
            ),
            CommandPaletteItem(
                id: "navigation.previous-needs-attention",
                category: "Navigation",
                title: "Previous Session Needing Attention",
                detail: "Jump back to a session waiting on a decision",
                shortcut: SessionAttentionShortcuts.previous.display,
                action: onPreviousNeedingAttention
            ),
            CommandPaletteItem(
                id: "navigation.next-workable",
                category: "Navigation",
                title: "Next Workable Session",
                detail: nil,
                shortcut: nil,
                action: onNextWorkable
            )
        ]
    }
}

private struct ScoredCommandItem {
    let score: Int
    let offset: Int
    let item: CommandPaletteItem
}

struct CommandPaletteView: View {
    let items: [CommandPaletteItem]
    let onDismiss: () -> Void
    let onOpenLinearIssue: (String) -> Void
    let onStartLinearIssue: (String) -> Void
    let onOpenPullRequest: (URL) -> Void
    let fallbackPullRequestURL: URL?
    let paletteCommands: [PaletteCommand]
    let onRunPaletteCommand: (PaletteCommand, String?, String) -> Void
    /// Agent profiles the picker's Tab key loops (plain shell excluded).
    /// A shared palette-level method: commands with no use for an agent
    /// simply ignore the selection.
    let agentProfiles: [NewSessionLaunch]
    /// Picked agent profile ID, or nil for Auto. Tab/Shift-Tab cycle it.
    @Binding var selectedAgentID: String?

    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var tabTrap: CommandPaletteTabTrap?
    @FocusState private var isSearchFocused: Bool

    private var resolvedItems: [CommandPaletteItem] {
        var items = items
        // Custom commands matching the query target surface first so typing
        // ENG-123 offers "Work on ENG-123" / "Verify ENG-123" above builtins.
        if let target = PaletteCommandTarget.detect(in: query) {
            for paletteCommand in paletteCommands.reversed()
            where paletteCommand.matches(target: target) {
                let captured = paletteCommand
                let value = target.value
                let rawQuery = query
                items.insert(
                    CommandPaletteItem(
                        id: "custom.quick.\(captured.id).\(value)",
                        category: "Custom · Quick Run",
                        title: captured.expandedTitle(target: value, query: rawQuery, agent: selectedAgentID),
                        detail: captured.expandedCommand(target: value, query: rawQuery, agent: selectedAgentID),
                        shortcut: "↩",
                        action: { onRunPaletteCommand(captured, value, rawQuery) }
                    ),
                    at: 0
                )
            }
        }
        if let linearID = CommandPaletteTargetResolver.linearIssueID(in: query) {
            items.insert(
                CommandPaletteItem(
                    id: "linear.quick-open.\(linearID)",
                    category: "Linear · Quick Open",
                    title: "Open Linear Issue \(linearID)",
                    detail: "Open in Linear",
                    shortcut: "↩",
                    action: { onOpenLinearIssue(linearID) }
                ),
                at: 0
            )
            items.insert(
                CommandPaletteItem(
                    id: "linear.quick-start.\(linearID)",
                    category: "Linear · Quick Open",
                    title: "Start Session for \(linearID)",
                    detail: "Create the issue worktree",
                    shortcut: nil,
                    action: { onStartLinearIssue(linearID) }
                ),
                at: 1
            )
        }
        if let pullRequestURL = CommandPaletteTargetResolver.pullRequestURL(
            in: query,
            fallback: fallbackPullRequestURL
        ) {
            items.insert(
                CommandPaletteItem(
                    id: "github.quick-open.\(pullRequestURL.absoluteString)",
                    category: "GitHub · Quick Open",
                    title: "Open Pull Request",
                    detail: pullRequestURL.absoluteString,
                    shortcut: "↩",
                    action: { onOpenPullRequest(pullRequestURL) }
                ),
                at: 0
            )
        }
        return items
    }

    private var filteredItems: [CommandPaletteItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return resolvedItems }
        let scoredItems: [ScoredCommandItem] = resolvedItems
            .enumerated()
            .compactMap { entry in
                let offset = entry.offset
                let item = entry.element
                guard let score = Self.matchScore(query, item: item) else { return nil }
                return ScoredCommandItem(score: score, offset: offset, item: item)
            }
        return scoredItems
            .sorted { (lhs: ScoredCommandItem, rhs: ScoredCommandItem) in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.offset < rhs.offset
            }
            .map(\.item)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    agentPickerMenu
                    TextField("Type a command or open a Linear/GitHub target", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($isSearchFocused)
                        .onSubmit(executeSelection)
                        .onExitCommand(perform: onDismiss)
                        .accessibilityIdentifier("banyan.commandPalette.search")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                if filteredItems.isEmpty {
                    ContentUnavailableView(
                        "No Matching Commands",
                        systemImage: "magnifyingglass",
                        description: Text("Try a command, session title, Linear ID, or GitHub PR.")
                    )
                    .frame(height: 180)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                    commandRow(item, isSelected: index == selectedIndex)
                                        .id(item.id)
                                        .onTapGesture {
                                            selectedIndex = index
                                            executeSelection()
                                        }
                                }
                            }
                            .padding(8)
                        }
                        .scrollIndicators(.hidden)
                        .hidesVerticalScroller()
                        .frame(maxHeight: 430)
                        .onChange(of: selectedIndex) { _, index in
                            guard filteredItems.indices.contains(index) else { return }
                            withAnimation(.easeOut(duration: 0.08)) {
                                proxy.scrollTo(filteredItems[index].id, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(width: 650)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15))
            }
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .accessibilityIdentifier("banyan.commandPalette")
        }
        .onAppear {
            selectedIndex = 0
            let trap = CommandPaletteTabTrap()
            tabTrap = trap
            trap.start()
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onDisappear {
            tabTrap?.stop()
            tabTrap = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .commandPaletteAgentNext)) { _ in
            cycleAgent(for: .down)
        }
        .onReceive(NotificationCenter.default.publisher(for: .commandPaletteAgentPrevious)) { _ in
            cycleAgent(for: .up)
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
        .onMoveCommand { direction in
            moveSelection(for: direction)
        }
        .onKeyPress(.upArrow) {
            moveSelection(for: .up)
            return .handled
        }
        .onKeyPress(.downArrow) {
            moveSelection(for: .down)
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            // Tab is the palette's agent-loop key: it must never advance the
            // window's key-view loop out of the palette into the terminal.
            // (The event-monitor trap normally swallows it first; this is the
            // fallback.) Tab cycles forward, Shift-Tab cycles back.
            guard press.key == .tab else { return .ignored }
            cycleAgent(for: press.modifiers.contains(.shift) ? .up : .down)
            isSearchFocused = true
            return .handled
        }
    }

    /// The picker's current profile, or nil for Auto / unknown IDs.
    private var selectedLaunch: NewSessionLaunch? {
        guard let selectedAgentID else { return nil }
        return agentProfiles.first { $0.id == selectedAgentID }
    }

    /// Agent picker replacing the search icon: click picks directly from a
    /// menu, Tab/Shift-Tab loop. Auto shows the magnifier, preserving the
    /// palette's previous look when no agent is picked.
    private var agentPickerMenu: some View {
        Menu {
            Button {
                selectedAgentID = nil
            } label: {
                Label("Auto", systemImage: "magnifyingglass")
            }
            ForEach(agentProfiles) { launch in
                Button {
                    selectedAgentID = launch.id
                } label: {
                    Label {
                        Text(launch.label)
                    } icon: {
                        launch.menuIconImage
                    }
                }
            }
        } label: {
            Group {
                if let selectedLaunch {
                    NewSessionLaunchIcon(launch: selectedLaunch, size: 16)
                } else {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(selectedLaunch.map { "Agent: \($0.label) — click to change, Tab cycles" } ?? "Agent: Auto — click to pick, Tab cycles")
        .accessibilityIdentifier("banyan.commandPalette.agentPicker")
    }

    /// Steps the picked agent, wrapping around Auto and every profile so Tab
    /// loops instead of stopping.
    private func cycleAgent(for direction: MoveCommandDirection) {
        selectedAgentID = Self.nextAgentID(
            selectedID: selectedAgentID,
            agents: agentProfiles,
            direction: direction
        )
    }

    /// Loop order is Auto (nil), then each agent profile in order, wrapping
    /// at either end. Unknown IDs are treated as Auto.
    static func nextAgentID(
        selectedID: String?,
        agents: [NewSessionLaunch],
        direction: MoveCommandDirection
    ) -> String? {
        let ids: [String?] = [nil] + agents.map(\.id)
        let current = ids.firstIndex(where: { $0 == selectedID }) ?? 0
        switch direction {
        case .down:
            return ids[(current + 1) % ids.count]
        case .up:
            return ids[(current + ids.count - 1) % ids.count]
        default:
            return selectedID
        }
    }

    /// Steps the highlighted row, wrapping around at either end so Up/Down
    /// loop through the options instead of stopping. (Tab cycles the agent
    /// picker, not the options.)
    private func moveSelection(for direction: MoveCommandDirection) {
        selectedIndex = Self.nextSelectedIndex(
            selectedIndex: selectedIndex,
            count: filteredItems.count,
            direction: direction
        )
    }

    static func nextSelectedIndex(
        selectedIndex: Int,
        count: Int,
        direction: MoveCommandDirection
    ) -> Int {
        guard count > 0 else { return 0 }
        switch direction {
        case .down:
            return (selectedIndex + 1) % count
        case .up:
            return (selectedIndex + count - 1) % count
        default:
            return min(max(selectedIndex, 0), count - 1)
        }
    }

    private func commandRow(_ item: CommandPaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(item.category)
                    if let detail = item.detail, !detail.isEmpty {
                        Text("·")
                        Text(detail)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
            }
        }
        .contentShape(Rectangle())
    }

    private func executeSelection() {
        guard filteredItems.indices.contains(selectedIndex) else { return }
        let item = filteredItems[selectedIndex]
        onDismiss()
        item.action()
    }

    private static func matchScore(_ query: String, item: CommandPaletteItem) -> Int? {
        let searchable = [item.category, item.title, item.detail ?? ""]
            .joined(separator: " ")
            .lowercased()
        let tokens = query.lowercased().split(whereSeparator: \ .isWhitespace)
        var score = 0
        var cursor = searchable.startIndex
        for token in tokens {
            let token = String(token)
            guard let range = searchable.range(of: token, range: cursor..<searchable.endIndex) else {
                guard searchable.contains(token) else { return nil }
                score += 5
                continue
            }
            score += 20
            if range.lowerBound == searchable.startIndex { score += 10 }
            score -= searchable.distance(from: searchable.startIndex, to: range.lowerBound)
            cursor = range.upperBound
        }
        return score
    }
}

enum CommandPaletteTargetResolver {
    static func linearIssueID(in query: String) -> String? {
        LinearIssueReference.issueID(in: query)
    }

    static func pullRequestURL(in query: String, fallback: URL?) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), isGitHubPullRequestURL(url) {
            return url
        }

        guard let hash = trimmed.lastIndex(of: "#"),
              let number = Int(trimmed[trimmed.index(after: hash)...]),
              number > 0 else {
            return nil
        }

        let repository: String
        let prefix = trimmed[..<hash].trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty {
            guard let fallback,
                  let components = URLComponents(url: fallback, resolvingAgainstBaseURL: false) else {
                return nil
            }
            let path = components.path.split(separator: "/").map(String.init)
            guard path.count >= 2 else { return nil }
            repository = path.prefix(2).joined(separator: "/")
        } else {
            let parts = prefix.split(separator: "/")
            guard parts.count == 2 else { return nil }
            repository = parts.map(String.init).joined(separator: "/")
        }

        return URL(string: "https://github.com/\(repository)/pull/\(number)")
    }

    private static func isGitHubPullRequestURL(_ url: URL) -> Bool {
        guard url.host?.lowercased() == "github.com" else { return false }
        let parts = url.path.split(separator: "/")
        return parts.count >= 4 && parts[2].lowercased() == "pull" && Int(parts[3]) != nil
    }
}

extension Notification.Name {
    /// Posted when the palette's Tab trap swallows a Tab keystroke: step the
    /// picked agent forward (wrapping through Auto and every profile).
    static let commandPaletteAgentNext = Notification.Name("banyan.commandPalette.agentNext")
    /// Posted when the palette's Tab trap swallows a Shift-Tab keystroke:
    /// step the picked agent back.
    static let commandPaletteAgentPrevious = Notification.Name("banyan.commandPalette.agentPrevious")
}

/// Swallows plain Tab / Shift-Tab while the command palette is open so focus
/// can never tab out of the palette into the terminal behind it.
///
/// A focused single-line search field hands Tab to AppKit's key-view loop via
/// the field editor (`insertTab:`), which consumes the keystroke before
/// SwiftUI's `.onKeyPress` ever sees it — so the trap has to be an event
/// monitor, which runs before dispatch. Swallowed keystrokes become agent
/// cycling instead: Tab steps to the next agent, Shift-Tab to the previous.
final class CommandPaletteTabTrap {
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard Self.matches(
                keyCode: event.keyCode,
                modifiers: event.modifierFlags,
                isRepeat: event.isARepeat
            ) else {
                return event
            }
            let name: Notification.Name = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .contains(.shift)
                ? .commandPaletteAgentPrevious
                : .commandPaletteAgentNext
            NotificationCenter.default.post(name: name, object: nil)
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    /// Plain Tab or Shift-Tab only (keyCode 48, no Command/Control/Option, not
    /// a repeat). System chords like ⌘⇥ (app switcher) must pass through.
    static func matches(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isRepeat: Bool
    ) -> Bool {
        guard !isRepeat, keyCode == 48 else { return false }
        let relevant = modifiers.intersection([.command, .control, .option, .shift])
        return relevant == [] || relevant == [.shift]
    }
}
