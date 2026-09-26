import AppKit
import BanyanCore
import SwiftUI
import UniformTypeIdentifiers

private enum LinearFocusTarget: Hashable {
    case filter
    case stateFilter
    case issueList
}

private enum LinearIssueSortOption: String, CaseIterable, Identifiable {
    case defaultOrder
    case updated
    case priority
    case title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .defaultOrder: return "Default order"
        case .updated: return "Recently updated"
        case .priority: return "Priority"
        case .title: return "Title"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: SessionStore
    @EnvironmentObject private var updater: AppUpdater
    private let selection: SessionSelection
    @State private var showingPreferences = false
    @State private var showingCommandPalette = false
    @State private var draggingSidebarSessionID: String?
    @State private var lastAutoScrolledSidebarSessionID: String?

    init(selection: SessionSelection) {
        self.selection = selection
    }

    @State private var linearIssueFilterText = ""
    @State private var selectedLinearIssueStateIDs: Set<String>?
    @State private var draftLinearIssueStateIDs: Set<String>?
    @State private var isLinearIssueStateFilterPresented = false
    @State private var linearIssueSortOption: LinearIssueSortOption = .defaultOrder
    @FocusState private var linearFocusTarget: LinearFocusTarget?

    @FocusState private var isSidebarSearchFocused: Bool

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                TitleBarLogo()
            }
            ToolbarItem(placement: .principal) {
                if let context = store.selectedContextInfo, context.hasTitlebarContent {
                    TitleBarContextView(
                        context: context,
                        onOpenLinear: store.openSelectedLinearIssue
                    )
                } else if let session = store.selectedSession {
                    TitleBarSessionFallbackView(session: session)
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let update = updater.pendingUpdate {
                    Button {
                        updater.install(update)
                    } label: {
                        Label("Upgrade", systemImage: "arrow.down.circle.fill")
                    }
                    .accessibilityIdentifier(AccessibilityID.toolbarUpdate)
                    .help("Install \(update.release.displayName) and relaunch")
                    .disabled(updater.isInstalling)
                }

                if store.canAttemptSelectedPullRequestPreview {
                    Button {
                        store.showSelectedPullRequestPreview()
                    } label: {
                        Image(systemName: "arrow.triangle.pull")
                    }
                    .accessibilityIdentifier(AccessibilityID.toolbarPullRequestLink)
                    .help(selectedPullRequestHelp)
                }

                Button {
                    store.spawnSiblingSession()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier(AccessibilityID.toolbarAddSession)
                .help("New sibling session")

                Button {
                    showingPreferences = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityIdentifier(AccessibilityID.toolbarPreferences)
                .help("Preferences")
            }
        }
        .sheet(item: addSessionDraftBinding) { draft in
            AddSessionSheet(draft: draft)
                .environmentObject(store)
        }
        .sheet(isPresented: $showingPreferences) {
            PreferencesSheet()
                .environmentObject(store)
        }
        .onAppear {
            store.loadPersistedSessionsIfNeeded()
            store.spawnDefaultSessionIfEmpty()
            store.refreshImportedHistoryIfNeeded()
            store.startControlServer()
            store.startSupervisor()
        }
        .onChange(of: store.commandPaletteRequestID) {
            showingCommandPalette = true
        }
        .alert(Text(closeConfirmationTitle), isPresented: closeConfirmationBinding) {
            Button("Cancel", role: .cancel) {}
            Button("Close and Kill", role: .destructive) {
                store.confirmPendingClose()
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text(closeConfirmationMessage)
        }
        .alert("Handoff", isPresented: handoffNoticeBinding) {
            Button("OK") {
                store.handoffNotice = nil
            }
        } message: {
            Text(store.handoffNotice ?? "")
        }
        .background(WindowTitleConfigurator(trigger: titlebarConfigurationTrigger))
        .preferredColorScheme(store.terminalTheme.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))) { _ in
            store.refreshTerminalAppearance()
        }
        .overlay {
            if showingCommandPalette {
                CommandPaletteView(
                    items: commandPaletteItems,
                    onDismiss: dismissCommandPalette,
                    onOpenLinearIssue: { issueID in
                        openLinearIssue(issueID)
                    },
                    onStartLinearIssue: store.startLinearIssueSession,
                    onOpenPullRequest: { url in NSWorkspace.shared.open(url) },
                    fallbackPullRequestURL: store.selectedPullRequestURL,
                    paletteCommands: store.paletteCommands,
                    onRunPaletteCommand: { command, target, query in
                        store.runPaletteCommand(command, target: target, query: query)
                    },
                    agentProfiles: store.paletteAgentProfiles,
                    selectedAgentID: $store.paletteAgentProfileID
                )
            }
        }
        .accessibilityIdentifier(AccessibilityID.root)
    }

    private func dismissCommandPalette() {
        showingCommandPalette = false
        store.focusSelectedTerminal()
    }

    /// Resolves a Linear issue id to the URL this host opens it at, honoring a
    /// configured base URL or org. Shared by the command palette and the sidebar
    /// suggestion banner so an issue id means the same destination wherever it
    /// is clicked.
    private func linearIssueURL(_ issueID: String) -> URL? {
        URL(string: LinearIssueReference.issueURL(
            for: issueID,
            environment: store.host.environment
        ))
    }

    /// Opens a Linear issue in the browser.
    private func openLinearIssue(_ issueID: String) {
        guard let url = linearIssueURL(issueID) else { return }
        NSWorkspace.shared.open(url)
    }

    private var commandPaletteItems: [CommandPaletteItem] {
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

        for (index, item) in store.sidebarSessions.enumerated() {
            let shortcut = JumpOverlayMonitor.shortcutDisplay(for: index + 1)
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

    private var sidebar: some View {
        VStack(spacing: 0) {
            switch store.sidebarMode {
            case .sessions:
                sessionsSidebar
            case .linear:
                linearSidebar
            }

            // Deliberately outside the mode switch: a palette command's result
            // must be visible from either sidebar, because the command may have
            // run from either one. The same goes for an inbound suggestion,
            // which arrives from outside the app and belongs to neither mode. It
            // sits above the run banner so the decision that is still open reads
            // as newer than the run that already happened.
            if let suggestion = store.pendingSuggestion {
                Divider()
                SuggestionBanner(
                    suggestion: suggestion,
                    onApprove: { store.approvePendingSuggestion() },
                    onDismiss: { store.dismissPendingSuggestion() },
                    issueURL: { issueID in linearIssueURL(issueID) }
                )
            }

            if let run = store.paletteCommandRun {
                Divider()
                PaletteCommandRunBanner(
                    run: run,
                    onRevealLog: { revealPaletteCommandLogs() },
                    onDismiss: { store.dismissPaletteCommandRun() }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(AccessibilityID.sidebar)
    }

    /// Opens the palette-command logs: the last run's file when there is one,
    /// otherwise the directory they accumulate in.
    private func revealPaletteCommandLogs() {
        let directory = PaletteCommandRunLog.directoryURL(host: store.host)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let logURL = store.paletteCommandRun?.logURL,
           FileManager.default.fileExists(atPath: logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }

    private var sidebarModeSwitcher: some View {
        Picker("Sidebar", selection: $store.sidebarMode) {
            ForEach(SidebarMode.allCases) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier(AccessibilityID.sidebarModePicker)
    }

    private var sessionsSidebar: some View {
        let groups = store.unifiedSidebarGroups
        let jumpKeyLabels = makeJumpKeyLabels(groups: groups)
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List {
                    sidebarSections(groups, jumpKeyLabels: jumpKeyLabels)
                }
                .listStyle(.sidebar)
                .scrollIndicators(.hidden)
                .hidesVerticalScroller()
                .accessibilityIdentifier(AccessibilityID.sidebarList)
                .onAppear {
                    guard let id = selection.selectedSessionID,
                          id != lastAutoScrolledSidebarSessionID,
                          store.unifiedSidebarGroups.flatMap(\.items).contains(where: { $0.id == id })
                    else { return }
                    lastAutoScrolledSidebarSessionID = id
                    // Defer one runloop so the List has laid out its rows before jumping.
                    DispatchQueue.main.async {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onReceive(selection.$selectedSessionID) { id in
                    guard let id,
                          id != lastAutoScrolledSidebarSessionID,
                          store.unifiedSidebarGroups.flatMap(\.items).contains(where: { $0.id == id })
                    else { return }
                    lastAutoScrolledSidebarSessionID = id
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }

            Spacer(minLength: 0)

            if !store.pendingHandoffJobs.isEmpty {
                Divider()
                PendingHandoffJobsView(jobs: store.pendingHandoffJobs)
            }

            if !store.recoverySessions.isEmpty {
                RecoverySessionsView(count: store.recoverySessions.count, onRecover: { store.recoverAll() })
                Divider()
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    store.spawnSiblingSession()
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier(AccessibilityID.sidebarAddSession)
                .help("New sibling session")

                Menu {
                    Button("Custom Session...") {
                        store.showCustomSessionSheet()
                    }
                    Button("Child Session...") {
                        store.showChildSessionSheet()
                    }
                    .disabled(store.selectedSession == nil)
                    Divider()
                    Picker("Sort", selection: $store.sortMode) {
                        ForEach(SortMode.allCases) { sortMode in
                            Text(sortMode.label).tag(sortMode)
                        }
                    }
                    Divider()
                    Toggle("Show finished children", isOn: $store.showFinishedChildren)
                        .help("Reveal completed child sessions in the sidebar")
                    Divider()
                    Button("Reveal Command Logs") {
                        revealPaletteCommandLogs()
                    }
                    .accessibilityIdentifier(AccessibilityID.sidebarRevealCommandLogs)
                    .help("Open the output of palette commands in Finder")
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityIdentifier(AccessibilityID.sidebarOptions)
                .help("Sidebar options")

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13, weight: .medium))

                    TextField("Search sessions", text: $store.historyFilterText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($isSidebarSearchFocused)
                        .accessibilityIdentifier(AccessibilityID.sidebarSearchField)
                        .onSubmit {
                            isSidebarSearchFocused = false
                            openFirstSearchMatch()
                        }

                    if !store.historyFilterText.isEmpty {
                        Button {
                            store.historyFilterText = ""
                            isSidebarSearchFocused = true
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.banyanPlain)
                        .help("Clear search")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                .layoutPriority(1)

                Spacer()

                sidebarModeSwitcher
            }
            .buttonStyle(.banyanBorderless)
            .padding(12)
            .accessibilityIdentifier(AccessibilityID.sidebarFooter)
        }
    }

    private var linearSidebar: some View {
        VStack(spacing: 0) {
            linearIssueFilterHeader

            Divider()

            linearListContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
                .clipped()

            HStack(spacing: 10) {
                Button {
                    store.refreshLinearIssueList()
                } label: {
                    if store.isLinearIssueListRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .accessibilityIdentifier(AccessibilityID.linearIssueListRefreshButton)
                .help("Refresh Linear issues")
                .disabled(store.isLinearIssueListRefreshing)

                Spacer(minLength: 0)

                Button {
                    store.startSelectedLinearListIssueSession()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .accessibilityIdentifier(AccessibilityID.linearIssueStartButton)
                .disabled(store.selectedLinearListIssueID == nil || store.linearIssueListLoadState.isStarting)
                .help("Start Banyan session for selected issue")

                sidebarModeSwitcher
            }
            .buttonStyle(.banyanBorderless)
            .padding(12)
            .accessibilityIdentifier(AccessibilityID.sidebarFooter)
        }
        .onAppear {
            linearFocusTarget = .issueList
            store.updateLinearIssueNavigationIDs(filteredLinearIssueIDs)
        }
        .onChange(of: store.linearFilterFocusRequestID) {
            linearFocusTarget = .filter
        }
        .onChange(of: filteredLinearIssueIDs) { _, ids in
            store.updateLinearIssueNavigationIDs(ids)
        }
    }

    private var linearIssueFilterHeader: some View {
        VStack(spacing: 6) {
            linearIssueSearchField
            HStack(spacing: 8) {
                linearIssueStateFilterMenu
                Text(issueCountLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
                linearIssueSortMenu
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var linearIssueSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Filter issues", text: $linearIssueFilterText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($linearFocusTarget, equals: .filter)
                .accessibilityIdentifier(AccessibilityID.linearIssueSearchField)
                .onKeyPress(.escape) {
                    linearIssueFilterText = ""
                    linearFocusTarget = .issueList
                    return .handled
                }

            if !linearIssueFilterText.isEmpty {
                Button {
                    linearIssueFilterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.banyanPlain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }

    private var linearIssueStateFilterMenu: some View {
        let states = availableLinearIssueStates
        return HStack(spacing: 8) {
            Button {
                draftLinearIssueStateIDs = selectedLinearIssueStateIDs
                isLinearIssueStateFilterPresented = true
            } label: {
                Label(linearIssueStateFilterLabel(availableStates: states), systemImage: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .buttonStyle(.banyanPlain)
            .popover(isPresented: $isLinearIssueStateFilterPresented, arrowEdge: .bottom) {
                linearIssueStateFilterPopover(states: states)
            }
            .focused($linearFocusTarget, equals: .stateFilter)
            .accessibilityIdentifier(AccessibilityID.linearIssueStateFilterMenu)
            .help("Filter Linear issues by state")

            Spacer(minLength: 0)
        }
    }

    private func linearIssueStateFilterPopover(states: [LinearWorkflowState]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleDraftAllLinearIssueStates()
            } label: {
                Label {
                    Text("All States")
                } icon: {
                    Image(systemName: draftLinearIssueStateCheckboxName)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .buttonStyle(.banyanPlain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if states.isEmpty {
                Text("No states loaded")
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(states) { state in
                            Toggle(isOn: draftLinearIssueStateBinding(for: state)) {
                                Label {
                                    Text(state.name)
                                } icon: {
                                    Circle()
                                        .fill(Color.linearHex(state.color))
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .scrollIndicators(.hidden)
                .hidesVerticalScroller()
                .frame(maxHeight: 320)

                Divider()

                HStack(spacing: 12) {
                    Button("Use Default States") {
                        draftLinearIssueStateIDs = nil
                    }
                    .buttonStyle(.banyanPlain)

                    Button("Show All States") {
                        draftLinearIssueStateIDs = Set(allLinearIssueStatesForFiltering.map(\.id))
                    }
                    .buttonStyle(.banyanPlain)
                }
                .padding(10)
            }
        }
        .frame(width: 260)
        .onDisappear {
            selectedLinearIssueStateIDs = draftLinearIssueStateIDs
        }
    }

    private var linearIssueSortMenu: some View {
        Menu {
            Picker("Sort", selection: $linearIssueSortOption) {
                ForEach(LinearIssueSortOption.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .accessibilityIdentifier(AccessibilityID.linearIssueSortMenu)
        .help("Sort Linear issues")
    }

    private var issueCountLabel: String {
        let count = filteredLinearIssues.count
        return "\(count) \(count == 1 ? "issue" : "issues")"
    }

    @ViewBuilder
    private var linearListContent: some View {
        switch store.linearIssueListLoadState {
        case .idle, .loading:
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading Linear issues...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                store.refreshLinearIssueListOnEnter()
            }
        case let .failed(message):
            if store.linearIssues.isEmpty {
                VStack(spacing: 10) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry") {
                        store.refreshLinearIssueList()
                    }
                    .buttonStyle(.banyanBordered)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            } else {
                VStack(spacing: 0) {
                    loadedLinearIssueListContent
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
            }
        case let .starting(issueID):
            VStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Starting \(issueID)...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if store.linearIssues.isEmpty {
                ContentUnavailableView(
                    "No Linear Issues",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Assigned Linear issues will appear here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                loadedLinearIssueListContent
            }
        }
    }

    @ViewBuilder
    private var loadedLinearIssueListContent: some View {
        let issues = filteredLinearIssues
        if issues.isEmpty {
            ContentUnavailableView(
                "No Matching Issues",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Clear or change the filter.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(issues) { issue in
                            LinearIssueRow(
                                issue: issue,
                                isSelected: store.selectedLinearListIssueID == issue.identifier,
                                onSelect: {
                                    store.selectedLinearListIssueID = issue.identifier
                                }
                            )
                            .id(issue.identifier)
                            .padding(.horizontal, 6)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .scrollIndicators(.hidden)
            .hidesVerticalScroller()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .clipped()
                .focusable()
                .focused($linearFocusTarget, equals: .issueList)
                .onChange(of: store.selectedLinearListIssueID) { _, issueID in
                    guard let issueID, issues.contains(where: { $0.identifier == issueID }) else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(issueID, anchor: .center)
                    }
                }
                .onKeyPress(.upArrow) {
                    moveLinearIssue(in: issues, direction: .previous)
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    moveLinearIssue(in: issues, direction: .next)
                    return .handled
                }
                .onKeyPress(.return) {
                    store.openSelectedLinearListIssue()
                    return .handled
                }
                .onKeyPress(.escape) {
                    linearFocusTarget = .filter
                    return .handled
                }
                .accessibilityIdentifier(AccessibilityID.linearIssueList)
            }
        }
    }

    private var filteredLinearIssueIDs: [String] {
        filteredLinearIssues.map(\.identifier)
    }

    private func moveLinearIssue(
        in issues: [LinearIssueSummary],
        direction: SessionSelectionDirection
    ) {
        let ids = issues.map(\.identifier)
        guard let issueID = SessionSelectionNavigator.adjacentID(
            in: ids,
            selectedID: store.selectedLinearListIssueID,
            direction: direction
        ) else {
            return
        }
        store.selectedLinearListIssueID = issueID
    }

    private var filteredLinearIssues: [LinearIssueSummary] {
        let tokens = linearIssueFilterText
            .split(whereSeparator: \.isWhitespace)
            .map { String($0) }
        let statesForFiltering = allLinearIssueStatesForFiltering
        let hasKnownStates = !statesForFiltering.isEmpty
        let visibleStateIDs = activeLinearIssueStateIDs(in: statesForFiltering)
        let visibleStateKeys = activeLinearIssueStateFilterKeys(
            in: statesForFiltering,
            activeStateIDs: visibleStateIDs
        )

        let matchingIssues = store.linearIssues.filter { issue in
            let matchesState = !hasKnownStates
                || visibleStateIDs.contains(issue.state.id)
                || visibleStateKeys.contains(issue.state.filterKey)
            let matchesText = tokens.isEmpty || issue.matchesFilterTokens(tokens)
            return matchesState && matchesText
        }

        switch linearIssueSortOption {
        case .defaultOrder:
            return matchingIssues
        case .updated:
            return matchingIssues.sorted { lhs, rhs in
                (lhs.updatedAt ?? "") > (rhs.updatedAt ?? "")
            }
        case .priority:
            return matchingIssues.sorted { lhs, rhs in
                switch (lhs.priority, rhs.priority) {
                case let (left?, right?):
                    if left != right { return left < right }
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): break
                }
                return lhs.identifier.localizedCaseInsensitiveCompare(rhs.identifier) == .orderedAscending
            }
        case .title:
            return matchingIssues.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    private var availableLinearIssueStates: [LinearWorkflowState] {
        var statesByID: [String: LinearWorkflowState] = [:]
        for state in store.linearIssueWorkflowStates {
            statesByID[state.id] = state
        }
        for issue in store.linearIssues {
            statesByID[issue.state.id] = issue.state
        }
        var statesByKey: [String: LinearWorkflowState] = [:]
        for state in statesByID.values {
            let key = state.filterKey
            if let existing = statesByKey[key] {
                statesByKey[key] = linearIssueStateSort(state, existing) ? state : existing
            } else {
                statesByKey[key] = state
            }
        }
        return statesByKey.values.sorted(by: linearIssueStateSort)
    }

    private var defaultLinearIssueStateIDs: Set<String> {
        defaultLinearIssueStateIDs(in: allLinearIssueStatesForFiltering)
    }

    private var activeLinearIssueStateIDs: Set<String> {
        activeLinearIssueStateIDs(in: allLinearIssueStatesForFiltering)
    }

    private var activeLinearIssueStateFilterKeys: Set<String> {
        activeLinearIssueStateFilterKeys(
            in: allLinearIssueStatesForFiltering,
            activeStateIDs: activeLinearIssueStateIDs
        )
    }

    private func defaultLinearIssueStateIDs(in states: [LinearWorkflowState]) -> Set<String> {
        Set(states.filter(\.isDefaultVisibleInLinearList).map(\.id))
    }

    private func activeLinearIssueStateIDs(in states: [LinearWorkflowState]) -> Set<String> {
        selectedLinearIssueStateIDs ?? defaultLinearIssueStateIDs(in: states)
    }

    private func activeLinearIssueStateFilterKeys(
        in states: [LinearWorkflowState],
        activeStateIDs: Set<String>
    ) -> Set<String> {
        Set(states.filter { activeStateIDs.contains($0.id) }.map(\.filterKey))
    }

    private func linearIssueStateFilterLabel(availableStates: [LinearWorkflowState]) -> String {
        guard !availableStates.isEmpty else { return "States" }
        let visibleCount = availableStates.filter { state in
            !activeLinearIssueStateIDs.intersection(linearIssueStateIDs(matching: state)).isEmpty
        }.count
        if selectedLinearIssueStateIDs == nil {
            return "Default states"
        }
        if visibleCount == availableStates.count {
            return "All states"
        }
        return "\(visibleCount) states"
    }

    private var draftLinearIssueStateCheckboxName: String {
        let allIDs = Set(allLinearIssueStatesForFiltering.map(\.id))
        let selectedIDs = draftLinearIssueStateIDs ?? defaultLinearIssueStateIDs(in: allLinearIssueStatesForFiltering)
        if !allIDs.isEmpty && selectedIDs.isSuperset(of: allIDs) {
            return "checkmark.square.fill"
        }
        if selectedIDs.isEmpty {
            return "square"
        }
        return "minus.square.fill"
    }

    private func draftLinearIssueStateBinding(for state: LinearWorkflowState) -> Binding<Bool> {
        Binding {
            let selectedIDs = draftLinearIssueStateIDs ?? defaultLinearIssueStateIDs(in: allLinearIssueStatesForFiltering)
            return !selectedIDs.intersection(linearIssueStateIDs(matching: state)).isEmpty
        } set: { isSelected in
            var selectedIDs = draftLinearIssueStateIDs ?? defaultLinearIssueStateIDs(in: allLinearIssueStatesForFiltering)
            let matchingIDs = linearIssueStateIDs(matching: state)
            if isSelected {
                selectedIDs.formUnion(matchingIDs)
            } else {
                selectedIDs.subtract(matchingIDs)
            }
            draftLinearIssueStateIDs = selectedIDs
        }
    }

    private func toggleDraftAllLinearIssueStates() {
        let allIDs = Set(allLinearIssueStatesForFiltering.map(\.id))
        let selectedIDs = draftLinearIssueStateIDs ?? defaultLinearIssueStateIDs(in: allLinearIssueStatesForFiltering)
        draftLinearIssueStateIDs = !allIDs.isEmpty && selectedIDs.isSuperset(of: allIDs) ? [] : allIDs
    }

    private var allLinearIssueStatesForFiltering: [LinearWorkflowState] {
        var statesByID: [String: LinearWorkflowState] = [:]
        for state in store.linearIssueWorkflowStates {
            statesByID[state.id] = state
        }
        for issue in store.linearIssues {
            statesByID[issue.state.id] = issue.state
        }
        return Array(statesByID.values)
    }

    private func linearIssueStateIDs(matching state: LinearWorkflowState) -> Set<String> {
        Set(allLinearIssueStatesForFiltering.filter { $0.filterKey == state.filterKey }.map(\.id))
    }

    private func linearIssueStateSort(_ lhs: LinearWorkflowState, _ rhs: LinearWorkflowState) -> Bool {
        switch (lhs.position, rhs.position) {
        case let (lhsPosition?, rhsPosition?):
            return lhsPosition < rhsPosition
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            let lhsType = lhs.type ?? ""
            let rhsType = rhs.type ?? ""
            if lhsType != rhsType {
                return lhsType.localizedCaseInsensitiveCompare(rhsType) == .orderedAscending
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    @ViewBuilder
    private func sidebarSections(
        _ groups: [SidebarSessionGroup],
        jumpKeyLabels: [String: String]
    ) -> some View {
        let firstGroupID = groups.first?.id
        ForEach(groups) { group in
            // The history and search groups are not user-reorderable and render
            // their rows dimmed, as a visual separator above the active sessions.
            let isStatic = group.id == "history" || group.id == "search"
            // The disclosure gutter is reserved for every row in the group as
            // soon as any row needs it, so same-depth badges line up and a
            // top-level parent never reads as a child of its sibling.
            let showsDisclosureGutter = group.items.contains { $0.isParent || $0.depth > 0 }
            Section {
                if isStatic {
                    ForEach(group.items) { item in
                        sidebarRow(
                            item,
                            groupID: group.id,
                            allowsDragSort: false,
                            isHistory: item.isHistory,
                            showsDisclosureGutter: showsDisclosureGutter,
                            jumpKeyLabel: jumpKeyLabels[item.id] ?? ""
                        )
                    }
                } else {
                    ForEach(group.items) { item in
                        sidebarRow(
                            item,
                            groupID: group.id,
                            allowsDragSort: true,
                            isHistory: false,
                            showsDisclosureGutter: showsDisclosureGutter,
                            jumpKeyLabel: jumpKeyLabels[item.id] ?? ""
                        )
                    }
                    .onMove { source, destination in
                        store.moveSidebarSessions(in: group.id, from: source, to: destination)
                    }
                }
            } header: {
                HStack(spacing: 4) {
                    Text(group.title)
                        .font(.caption)
                        .foregroundStyle(isStatic ? .tertiary : .secondary)
                        .lineLimit(1)

                    if !isStatic {
                        Spacer(minLength: 4)

                        ProjectNewSessionButton(groupID: group.id, groupTitle: group.title)
                    }
                }
                // Only the first project gets extra top breathing room under the
                // mode-picker divider; adding it to every header widened the gaps
                // between projects. The history/search header gets a touch more
                // space so it reads as a separator above the active rows.
                .padding(.top, group.id == firstGroupID ? 4 : (isStatic ? 8 : 0))
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Sticky headers float over scrolled rows. Materials
                // (.bar/.ultraThickMaterial) are blurs, not opaque fills,
                // so high-contrast row text still bled through in dark mode.
                // Use an opaque sidebar-matching fill instead.
                .background(Color(nsColor: .windowBackgroundColor))
            }
            .listSectionSeparator(isStatic ? .visible : .hidden, edges: .top)
        }
    }

    private func makeJumpKeyLabels(
        groups: [SidebarSessionGroup]
    ) -> [String: String] {
        // Use the projections already produced for this render. Looking labels up
        // through SessionStore for every row rebuilt and resorted the full history
        // backlog once per displayed session.
        var labels: [String: String] = [:]
        var position = 1
        for group in groups {
            for item in group.items {
                if let label = JumpOverlayMonitor.jumpLabel(for: position) {
                    labels[item.id] = label
                }
                position += 1
            }
        }
        return labels
    }

    private func sidebarRow(
        _ item: SidebarSessionItem,
        groupID: String,
        allowsDragSort: Bool,
        isHistory: Bool,
        showsDisclosureGutter: Bool,
        jumpKeyLabel: String
    ) -> some View {
        SessionRow(
            session: item.session,
            selection: selection,
            launchProfile: store.sessionLaunchProfile(for: item.session),
            depth: item.depth,
            titleOverride: item.titleOverride,
            isHistory: isHistory,
            isParent: item.isParent,
            showsDisclosureGutter: showsDisclosureGutter,
            isCollapsed: item.isCollapsed,
            hiddenChildCount: item.hiddenChildCount,
            jumpKeyLabel: jumpKeyLabel,
            onSelect: {
                store.userSelect(id: item.session.id)
            },
            onToggleCollapse: {
                store.toggleChildrenCollapsed(for: item.session.id)
            },
            onRevealHidden: {
                if item.isCollapsed {
                    store.toggleChildrenCollapsed(for: item.session.id)
                } else {
                    store.showFinishedChildren = true
                }
            },
            onClose: {
                store.requestClose(id: item.session.id)
            },
            onRestart: {
                try? store.restart(id: item.session.id)
            },
            onRespawn: {
                try? store.respawn(id: item.session.id)
            },
            onRecover: {
                try? store.recover(id: item.session.id)
            },
            isHandoffAvailable: store.isHandoffAvailable,
            isHandoffPending: store.isHandoffPending(for: item.session.id),
            onHandoff: {
                store.dispatchHandoff(id: item.session.id)
            },
            onRemove: {
                try? store.remove(id: item.session.id)
            },
            onToggleSuspended: {
                try? store.toggleSuspended(id: item.session.id)
            },
            onFocusTerminal: {
                store.focusSelectedTerminal()
            },
            onReopenHistory: {
                reopenHistory(item)
            }
        )
        .id(item.session.id)
        .tag(item.session.id)
        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
        .modifier(SidebarDragSortModifier(
            sessionID: item.session.id,
            groupID: groupID,
            isEnabled: allowsDragSort,
            draggingSessionID: $draggingSidebarSessionID,
            onMove: store.moveSidebarSession
        ))
    }

    private func openFirstSearchMatch() {
        guard !store.historyFilterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let item = store.unifiedSidebarGroups.flatMap(\.items).first else {
            return
        }

        if item.isHistory {
            reopenHistory(item)
        } else {
            store.userSelect(id: item.session.id)
        }
    }

    private func reopenHistory(_ item: SidebarSessionItem) {
        if item.session.isImportedHistory {
            _ = try? store.resumeImportedHistory(id: item.session.id)
        } else {
            try? store.respawn(id: item.session.id)
        }
    }

    private var addSessionDraftBinding: Binding<AddSessionDraft?> {
        Binding {
            store.addSessionDraft
        } set: { draft in
            store.addSessionDraft = draft
        }
    }

    private var closeConfirmationBinding: Binding<Bool> {
        Binding {
            store.pendingCloseSession != nil
        } set: { isPresented in
            if !isPresented {
                store.cancelPendingClose()
            }
        }
    }

    private var closeConfirmationMessage: String {
        guard let session = store.pendingCloseSession else {
            return ""
        }
        var details = ["Closing \(session.displayTitle) will kill its tmux session."]
        if store.pendingCloseHasOngoingAgent {
            details.append("Any running coding-agent process in that session will be terminated.")
        }
        if store.pendingCloseHasActiveChildren {
            details.append("Child sessions will be detached to the same level as this parent session.")
        }
        return details.joined(separator: " ")
    }

    private var handoffNoticeBinding: Binding<Bool> {
        Binding(
            get: { store.handoffNotice != nil },
            set: { isPresented in
                if !isPresented {
                    store.handoffNotice = nil
                }
            }
        )
    }


    private var closeConfirmationTitle: String {
        if store.pendingCloseHasOngoingAgent {
            return "Close running agent?"
        }
        return "Close parent session?"
    }

    private var titlebarConfigurationTrigger: String {
        guard let session = store.selectedSession else { return "none" }
        return [
            session.id,
            session.displayTitle,
            session.cwd,
            store.selectedContextInfo?.linearIssueID ?? "",
            store.selectedContextInfo?.pullRequestURL ?? ""
        ].joined(separator: "|")
    }

    private var selectedPullRequestHelp: String {
        guard let context = store.selectedContextInfo else {
            return "Preview GitHub pull request"
        }
        if let number = context.pullRequestNumber {
            return "Preview GitHub pull request #\(number)"
        }
        if let title = context.pullRequestTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return "Preview GitHub pull request: \(title)"
        }
        return "Preview GitHub pull request"
    }

    @ViewBuilder
    private var detail: some View {
        switch store.sidebarMode {
        case .sessions:
            sessionDetail
        case .linear:
            linearDetail
        }
    }

    @ViewBuilder
    private var sessionDetail: some View {
        HStack(spacing: 0) {
            ZStack {
                SelectionAwareTerminalSwitcher(
                    selection: selection,
                    sessions: store.visibleSessions,
                    theme: store.terminalTheme,
                    fontFamily: store.terminalFontFamily,
                    fontSize: store.terminalFontSize,
                    focusRequestID: store.terminalFocusRequestID,
                    switchRequestedAt: store.sessionSwitchRequestedAt
                )
                .ignoresSafeArea(edges: .bottom)

                if let session = store.selectedSession {
                    if session.status == .closed {
                        ClosedSessionHistoryView(session: session)
                    } else if session.isImportedHistory {
                        ImportedSessionHistoryView(session: session)
                    } else if session.isSuspended {
                        VStack(spacing: 0) {
                            SuspendedSessionBanner(session: session)
                            Divider()
                            Spacer()
                        }
                        .background(.background)
                    } else if session.needsManualAttach {
                        VStack(spacing: 0) {
                            TerminalReconnectBanner(session: session)
                            Divider()
                            Spacer()
                        }
                        .background(.background)
                    }
                } else {
                    ContentUnavailableView(
                        "No Session Selected",
                        systemImage: "terminal",
                        description: Text("Spawn a session from the toolbar or with banyanctl.")
                    )
                    .accessibilityIdentifier(AccessibilityID.emptyDetail)
                }
            }
            // SwiftTerm owns a Metal-backed surface. During restoration SwiftUI
            // can briefly propose the panel's fixed width before it proposes the
            // remaining detail width; never collapse that surface to a sliver.
            .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            if let session = store.selectedSession {
                if store.isPullRequestPreviewPresented,
                   let context = store.selectedPullRequestPreviewContext,
                   session.status != .closed {
                    issuePreviewPanel {
                        PullRequestPreviewPanel(
                            context: context,
                            details: store.selectedPullRequestDetails,
                            loadState: store.selectedPullRequestLoadState,
                            onRefresh: {
                                store.refreshSelectedPullRequestPreview(force: true)
                            },
                            onOpen: store.openSelectedPullRequest,
                            onClose: store.closePullRequestPreview
                        )
                    }
                } else if let context = store.selectedContextInfo,
                          context.githubIssueURL?.isEmpty == false,
                          session.status != .closed {
                    issuePreviewPanel {
                        GitHubIssuePanel(
                            context: context,
                            issue: store.selectedGitHubIssueDetails,
                            loadState: store.selectedGitHubIssueLoadState,
                            onRefresh: { store.refreshSelectedGitHubIssue(force: true) },
                            onOpen: store.openSelectedGitHubIssue
                        )
                        .onAppear { store.refreshSelectedGitHubIssue(force: true) }
                    }
                } else if let context = store.selectedContextInfo,
                          context.linearIssueID?.isEmpty == false,
                          session.status != .closed {
                    issuePreviewPanel {
                        LinearIssuePanel(
                            context: context,
                            issue: store.selectedLinearIssueDetails,
                            loadState: store.selectedLinearIssueLoadState,
                            onRefresh: {
                                store.refreshSelectedLinearIssue(force: true)
                            },
                            onOpen: store.openSelectedLinearIssue,
                            onChangeState: store.updateSelectedLinearIssueState,
                            onToggleTask: store.updateSelectedLinearIssueDescription,
                            onRetryDescription: store.retrySelectedLinearIssueDescription
                        )
                        .onAppear {
                            store.refreshSelectedLinearIssue(force: true)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.detail)
    }

    @ViewBuilder
    private func issuePreviewPanel<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: 0) {
            Divider()
            content()
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .shadow(
                    color: .black.opacity(0.14),
                    radius: 12,
                    x: -4,
                    y: 0
                )
                .padding(.vertical, 10)
                .padding(.leading, 10)
                .padding(.trailing, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background)
    }

    @ViewBuilder
    private var linearDetail: some View {
        Group {
            if let context = store.selectedLinearListIssueContext {
                LinearIssuePanel(
                    context: context,
                    issue: store.selectedLinearListIssueDetails,
                    loadState: store.selectedLinearListIssueLoadState,
                    onRefresh: {
                        store.refreshSelectedLinearListIssue(force: true)
                    },
                    onOpen: store.openSelectedLinearListIssue,
                    onChangeState: store.updateSelectedLinearListIssueState,
                    onToggleTask: store.updateSelectedLinearListIssueDescription,
                    onRetryDescription: store.retrySelectedLinearListIssueDescription,
                    onStart: store.startSelectedLinearListIssueSession,
                    isStarting: store.linearIssueListLoadState.isStarting,
                    presentation: .main
                )
            } else {
                ContentUnavailableView(
                    "No Linear Issue Selected",
                    systemImage: "list.bullet.rectangle",
                    description: Text("Select an issue from the Linear sidebar.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            store.refreshLinearIssueListIfNeeded()
            store.refreshSelectedLinearListIssue(force: true)
        }
        .accessibilityIdentifier(AccessibilityID.detail)
    }

}

private extension SessionContextInfo {
    var hasTitlebarContent: Bool {
        let hasLinearTitle = linearIssueID?.isEmpty == false
            && linearIssueTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return hasLinearTitle
    }
}

private struct LinearIssueRow: View {
    let issue: LinearIssueSummary
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(issue.identifier)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .lineLimit(1)
                statusPill
                Spacer(minLength: 0)
            }

            Text(issue.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(2)
                .truncationMode(.tail)

            HStack(spacing: 6) {
                metadataText(issue.projectName, fallback: "No project")
                metadataText(issue.priorityLabel ?? priorityLabel, fallback: nil)
                metadataText(issue.cycleName, fallback: nil)
            }
            .font(.caption2)
            .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 72, alignment: .center)
        .padding(.horizontal, 8)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor)
        } else {
            Color.clear
        }
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isSelected ? Color.white : Color.linearHex(issue.state.color))
                .frame(width: 6, height: 6)
            Text(issue.state.name)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption2)
        .frame(maxWidth: 92, alignment: .leading)
        .clipped()
    }

    @ViewBuilder
    private func metadataText(_ value: String?, fallback: String?) -> some View {
        if let value, !value.isEmpty {
            Text(value)
        } else if let fallback {
            Text(fallback)
        }
    }

    private var priorityLabel: String? {
        guard let priority = issue.priority, priority > 0 else { return nil }
        return "P\(priority)"
    }
}

private extension LinearIssueSummary {
    func matchesFilterTokens(_ tokens: [String]) -> Bool {
        let haystack = [
            identifier,
            title,
            state.name,
            state.type,
            priority.map { "P\($0)" },
            priorityLabel,
            assigneeName,
            teamKey,
            teamName,
            projectName,
            cycleName,
            labels.map(\.name).joined(separator: " ")
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        return tokens.allSatisfy { token in
            haystack.contains(
                token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            )
        }
    }
}

private extension LinearWorkflowState {
    var filterKey: String {
        [
            name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
            type ?? ""
        ].joined(separator: "|")
    }

    var isDefaultVisibleInLinearList: Bool {
        guard !isOnHoldState else { return false }
        guard let type = type?.lowercased() else { return true }
        return ["triage", "backlog", "unstarted", "started"].contains(type)
    }

    private var isOnHoldState: Bool {
        let normalizedName = name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
        return normalizedName == "onhold"
    }
}

private extension LinearIssueListLoadState {
    var isStarting: Bool {
        if case .starting = self {
            return true
        }
        return false
    }

    func isStarting(_ issueID: String) -> Bool {
        if case let .starting(startingIssueID) = self {
            return startingIssueID == issueID
        }
        return false
    }
}

private struct TitleBarContextView: View {
    let context: SessionContextInfo
    let onOpenLinear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let issueID = context.linearIssueID,
               let linearIssueTitle = sanitizedLinearIssueTitle {
                TitleBarContextButton(
                    accessibilityIdentifier: AccessibilityID.toolbarLinearLink,
                    systemImage: "list.bullet.rectangle",
                    primary: issueID,
                    secondary: linearIssueTitle,
                    help: "Open Linear issue (Cmd-L)",
                    isEnabled: true,
                    action: onOpenLinear
                )
            }
        }
        .frame(maxWidth: 560)
        .padding(.horizontal, 10)
        .lineLimit(1)
        .accessibilityIdentifier(AccessibilityID.toolbarContext)
    }

    private var sanitizedLinearIssueTitle: String? {
        let trimmed = context.linearIssueTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

/// Toolbar fallback for sessions with no bound Linear issue: show the session's
/// display title (first prompt for agent sessions) instead of leaving the
/// titlebar empty. Plain shells stay empty — only agent sessions get a label.
private struct TitleBarSessionFallbackView: View {
    @ObservedObject var session: BanyanSession

    var body: some View {
        if session.agentProvider != nil, let title = fallbackTitle {
            HStack(spacing: 6) {
                if let provider = session.displayAgentProvider {
                    AgentProviderIcon(provider: provider, size: 14, showsPeakBadge: false)
                }
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            // The toolbar pins flexible principal items at ~370px regardless of
            // maxWidth or ideal size, but honors an explicit width — so measure
            // the text (same 12pt system font) and demand exactly that.
            .frame(width: fittedWidth(for: title))
            .padding(.horizontal, 10)
            .lineLimit(1)
            .accessibilityIdentifier(AccessibilityID.toolbarSessionTitle)
        }
    }

    private func fittedWidth(for title: String) -> CGFloat {
        let textWidth = (title as NSString).size(
            withAttributes: [.font: NSFont.systemFont(ofSize: 12)]
        ).width
        let chrome: CGFloat = (session.displayAgentProvider != nil ? 14 + 6 : 0) + 20 + 8
        return min(max(textWidth + chrome, 140), 1100)
    }

    private var fallbackTitle: String? {
        let trimmed = session.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct TitleBarContextButton: View {
    let accessibilityIdentifier: String
    let systemImage: String
    let primary: String
    let secondary: String?
    let help: String
    let isEnabled: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(primary)
                    .font(.system(size: 12, weight: .semibold))
                    .underline(isEnabled && isHovered)
                if let secondary = sanitizedSecondary {
                    Text(secondary)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.banyanPlainLabelOnly)
        .onHover { isHovered = isEnabled && $0 }
        .onDisappear { isHovered = false }
        .disabled(!isEnabled)
        .help(help)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var sanitizedSecondary: String? {
        let trimmed = secondary?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

}

private struct TitleBarLogo: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 86, height: 28))
        container.identifier = NSUserInterfaceItemIdentifier(AccessibilityID.toolbarLogo)
        container.setAccessibilityElement(true)
        container.setAccessibilityLabel("Banyan")
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor

        let iconView = NSImageView(image: Self.logoImage)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(iconView)

        let label = NSTextField(labelWithString: "Banyan")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        container.addSubview(label)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: 86),
            container.heightAnchor.constraint(equalToConstant: 28),
            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 7),
            iconView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8)
        ])

        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let iconView = nsView.subviews.first as? NSImageView {
            iconView.image = Self.logoImage
        }
    }

    private static var logoImage: NSImage {
        if let url = Bundle.main.url(forResource: "Banyan", withExtension: "icns"),
           let bundled = NSImage(contentsOf: url) {
            return bundled
        }
        if let bundled = NSImage(named: "Banyan") {
            return bundled
        }
        return NSApp.applicationIconImage
    }
}

private struct WindowTitleConfigurator: NSViewRepresentable {
    let trigger: String

    func makeNSView(context: Context) -> NSView {
        TitlebarConfigurationView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            Self.configure(window: nsView.window)
        }
    }

    fileprivate static func configure(window: NSWindow?) {
        guard let window else { return }
        WindowRestorationPolicy.configure(window)
        window.title = " "
        window.titleVisibility = .visible
    }
}

private final class TitlebarConfigurationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        configureTitlebar()
    }

    private func configureTitlebar() {
        DispatchQueue.main.async { [weak self] in
            WindowTitleConfigurator.configure(window: self?.window)
        }
    }
}

private struct SidebarDragSortModifier: ViewModifier {
    let sessionID: String
    let groupID: String
    let isEnabled: Bool
    @Binding var draggingSessionID: String?
    let onMove: (String, String, String) -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .opacity(draggingSessionID == sessionID ? 0.55 : 1)
                .onDrag {
                    draggingSessionID = sessionID
                    let provider = NSItemProvider()
                    provider.registerDataRepresentation(
                        forTypeIdentifier: SidebarSessionDrag.type.identifier,
                        visibility: .ownProcess
                    ) { completion in
                        completion(Data(sessionID.utf8), nil)
                        return nil
                    }
                    return provider
                }
                .onDrop(
                    of: [SidebarSessionDrag.type],
                    delegate: SidebarSessionDropDelegate(
                        targetSessionID: sessionID,
                        groupID: groupID,
                        draggingSessionID: $draggingSessionID,
                        onMove: onMove
                    )
                )
        } else {
            content
        }
    }
}

private struct SidebarSessionDropDelegate: DropDelegate {
    let targetSessionID: String
    let groupID: String
    @Binding var draggingSessionID: String?
    let onMove: (String, String, String) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        draggingSessionID != nil && info.hasItemsConforming(to: [SidebarSessionDrag.type])
    }

    func dropEntered(info: DropInfo) {
        guard let draggingSessionID, draggingSessionID != targetSessionID else { return }
        onMove(draggingSessionID, targetSessionID, groupID)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard draggingSessionID != nil else { return false }
        self.draggingSessionID = nil
        return true
    }
}

private enum SidebarSessionDrag {
    static let type = UTType(exportedAs: "dev.banyudu.banyan.sidebar-session")
}

private struct PendingHandoffJobsView: View {
    let jobs: [HandoffJob]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Handoff")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            ForEach(jobs) { job in
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                        .frame(width: 16, height: 16)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(job.title)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text("Dispatching")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier(AccessibilityID.sidebarPendingHandoffJobs)
    }
}

private struct RecoverySessionsView: View {
    let count: Int
    let onRecover: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(.orange)
            Text(count == 1 ? "1 session needs recovery" : "\(count) sessions need recovery")
                .font(.caption)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Recover All", action: onRecover)
                .buttonStyle(.banyanBorderedProminent)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityIdentifier("banyan.sidebar.recovery")
    }
}

/// Reports the last palette command the app ran.
///
/// This is the visible half of the fix for "the Review command did nothing":
/// background commands write their output to a log rather than a terminal, so
/// without this the only signal was a session appearing (or not) some seconds
/// later. Failures keep the command's own last line and the log location on
/// screen until dismissed.
private struct PaletteCommandRunBanner: View {
    let run: PaletteCommandRun
    let onRevealLog: () -> Void
    let onDismiss: () -> Void

    @State private var isOutputExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                statusIcon
                    .frame(width: 16, height: 16)

                Text(run.headline)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)

                Spacer(minLength: 4)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.banyanPlain)
                .accessibilityIdentifier(AccessibilityID.sidebarPaletteCommandRunDismiss)
                .help("Dismiss")
            }

            if !run.command.isEmpty {
                Text(run.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            if let detail = run.failureDetail, !isOutputExpanded {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            if isOutputExpanded {
                ScrollView {
                    Text(run.outputTail)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 180)
                .padding(6)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier(AccessibilityID.sidebarPaletteCommandRunOutput)
            }

            HStack(spacing: 6) {
                if run.hasOutput {
                    Button(isOutputExpanded ? "Hide Output" : "Show Output") {
                        isOutputExpanded.toggle()
                    }
                    .accessibilityIdentifier(AccessibilityID.sidebarPaletteCommandRunToggleOutput)
                }
                if run.logURL != nil {
                    Button("Reveal Log", action: onRevealLog)
                        .accessibilityIdentifier(AccessibilityID.sidebarPaletteCommandRunRevealLog)
                }
                if run.isOutputTruncated {
                    Text("earlier output trimmed")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.banyanBordered)
            .controlSize(.small)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(AccessibilityID.sidebarPaletteCommandRun)
        // The countdown lives here rather than in the store so it can see the
        // output panel: a success that the user has opened up to read is a
        // success they are still using, and it waits. Keying on the run and the
        // armed flag together restarts the countdown when a run settles, and
        // cancels it the moment the banner goes away.
        .task(id: AutoDismissKey(runID: run.id, isArmed: isAutoDismissArmed)) {
            guard isAutoDismissArmed else { return }
            try? await Task.sleep(nanoseconds: UInt64(PaletteCommandRun.autoDismissDelay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            onDismiss()
        }
    }

    /// A settled success clears itself, unless the user has expanded its output.
    private var isAutoDismissArmed: Bool {
        run.autoDismisses && !isOutputExpanded
    }

    /// Restarting the countdown needs both halves: the run it belongs to, and
    /// whether it is armed at all.
    private struct AutoDismissKey: Equatable {
        let runID: UUID
        let isArmed: Bool
    }

    @ViewBuilder
    private var statusIcon: some View {
        if run.isRunning {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.65)
        } else if run.isFailure {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
    }
}

/// Presents one inbound suggestion and the two things the human can do with it.
///
/// This is the whole of Banyan's half of the suggestion channel: the policy that
/// decided this issue was worth raising lives in whatever script called
/// `banyanctl suggest`. The command is shown verbatim rather than summarised,
/// because approving runs it — the user should be able to read what they are
/// agreeing to before they agree to it.
///
/// While the banner is on screen the pending decision can also be answered from
/// the keyboard (`SuggestionShortcuts`): the banner owns the monitor, so the
/// chords are live exactly as long as there is something to answer.
private struct SuggestionBanner: View {
    let suggestion: InboundSuggestion
    let onApprove: () -> Void
    let onDismiss: () -> Void
    /// Resolves a Linear issue id to the URL the host opens it at. The banner
    /// renders the ids it is given (`suggestion.title`, `suggestion.target`) as
    /// links through this, so an id means the same destination it does in the
    /// command palette.
    let issueURL: (String) -> URL?

    /// Installed on appear and torn down on disappear, matching the lifetime of
    /// the pending suggestion this banner is showing.
    @State private var shortcutMonitor: SuggestionShortcutMonitor?
    @State private var isTitleLinkHovered = false
    @State private var isTargetLinkHovered = false

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow)
                    .frame(width: 16, height: 16)

                titleLabel

                Spacer(minLength: 4)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.banyanPlain)
                .accessibilityIdentifier(AccessibilityID.sidebarSuggestionDismiss)
                .help("Dismiss this suggestion (\(SuggestionShortcuts.dismissDisplay))")
            }

            if let detail = suggestion.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(suggestion.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                Button("Run \(SuggestionShortcuts.approveDisplay)", action: onApprove)
                    .accessibilityIdentifier(AccessibilityID.sidebarSuggestionApprove)
                    .accessibilityLabel("Run")
                    .help("Run this suggestion (\(SuggestionShortcuts.approveDisplay))")
                if let target = suggestion.target {
                    Button {
                        if let url = issueURL(target) { openURL(url) }
                    } label: {
                        Text(target)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .underline(isTargetLinkHovered)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .banyanButtonHoverEffect(.labelOnly) { isTargetLinkHovered = $0 }
                    .accessibilityIdentifier(AccessibilityID.sidebarSuggestionTarget)
                    .accessibilityLabel("Open \(target) in Linear")
                    .help("Open \(target) in Linear")
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.banyanBordered)
            .controlSize(.small)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(AccessibilityID.sidebarSuggestion)
        .onAppear {
            let monitor = SuggestionShortcutMonitor()
            shortcutMonitor = monitor
            monitor.start()
        }
        .onDisappear {
            shortcutMonitor?.stop()
            shortcutMonitor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .suggestionApprove)) { _ in
            onApprove()
        }
        .onReceive(NotificationCenter.default.publisher(for: .suggestionDismiss)) { _ in
            onDismiss()
        }
    }

    /// The title, with a leading issue id (`ENG-12355: …`) rendered as a link
    /// into Linear. Titles that do not lead with an id stay plain text.
    ///
    /// The id and the text after it are one `Text` rather than a link beside a
    /// label, because two sibling views wrap independently: the label would
    /// wrap inside its own, narrower frame, starting every line after the first
    /// indented under the id instead of back at the card's leading edge.
    @ViewBuilder
    private var titleLabel: some View {
        if let split = leadingIssueID {
            Text(linkedTitle(split))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .onHover { isTitleLinkHovered = $0 }
        } else {
            Text(suggestion.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The title with its leading id linked into Linear, so a click on the id
    /// opens the issue while the rest of the title stays inert text. The id
    /// keeps the title's own colour instead of taking the link tint, and
    /// underlines on hover like the card's other link — that hover is the whole
    /// title's, since a `Text` cannot report which run the pointer is over.
    private func linkedTitle(_ split: (id: String, remainder: String)) -> AttributedString {
        var idRun = AttributedString(split.id)
        idRun.link = issueURL(split.id)
        idRun.foregroundColor = .primary
        if isTitleLinkHovered {
            idRun.underlineStyle = .single
        }
        return idRun + AttributedString(split.remainder)
    }

    /// Splits a title like `ENG-12355: Design proposal` into the leading issue
    /// id and the text that follows it, so only the id becomes a link. Returns
    /// nil when the title has no id, or the id is not at the start.
    private var leadingIssueID: (id: String, remainder: String)? {
        guard let id = LinearIssueReference.issueID(in: suggestion.title),
              let range = suggestion.title.range(of: id),
              range.lowerBound == suggestion.title.startIndex else {
            return nil
        }
        return (id, String(suggestion.title[range.upperBound...]))
    }
}

/// The two ways to answer a pending suggestion from the keyboard, defined once
/// so the monitor that swallows the chord and the tooltip that advertises it
/// cannot drift apart.
enum SuggestionShortcuts {
    static let approveDisplay = "⌘⇧↩"
    static let dismissDisplay = "⌘⇧⌫"

    enum Match {
        case approve
        case dismiss
    }

    /// `⌘⇧↩` or `⌘⇧⌫` with no other modifiers, and not an auto-repeat. Return
    /// and keypad Enter are treated alike, as are the two Delete keys.
    static func match(_ event: NSEvent) -> Match? {
        matches(keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat)
    }

    static func matches(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isRepeat: Bool
    ) -> Match? {
        guard !isRepeat else { return nil }
        let relevant = modifiers.intersection([.command, .shift, .control, .option])
        guard relevant == [.command, .shift] else { return nil }
        switch keyCode {
        case 36, 76: return .approve
        case 51, 117: return .dismiss
        default: return nil
        }
    }
}

extension Notification.Name {
    /// Posted when the suggestion banner's shortcut monitor swallows `⌘⇧↩`.
    static let suggestionApprove = Notification.Name("banyan.suggestion.approve")
    /// Posted when the suggestion banner's shortcut monitor swallows `⌘⇧⌫`.
    static let suggestionDismiss = Notification.Name("banyan.suggestion.dismiss")
}

/// Swallows `⌘⇧↩` / `⌘⇧⌫` while a suggestion banner is on screen so the pending
/// decision can be answered without reaching for the mouse.
///
/// A focused terminal consumes keystrokes before SwiftUI's key equivalents run,
/// so this has to be an event monitor rather than a `.keyboardShortcut` on the
/// buttons. It is installed only for as long as the banner is visible, so the
/// chords are never hijacked when there is nothing to answer.
final class SuggestionShortcutMonitor {
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let match = SuggestionShortcuts.match(event) else { return event }
            NotificationCenter.default.post(
                name: match == .approve ? .suggestionApprove : .suggestionDismiss,
                object: nil
            )
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

/// Keeps fast selection invalidation scoped to the terminal representable instead
/// of rebuilding the entire navigation split rooted at `ContentView`.
private struct SelectionAwareTerminalSwitcher: View {
    @ObservedObject var selection: SessionSelection
    let sessions: [BanyanSession]
    let theme: TerminalTheme
    let fontFamily: String
    let fontSize: Double
    let focusRequestID: UUID
    let switchRequestedAt: DispatchTime?

    var body: some View {
        TerminalSwitcherView(
            sessions: sessions,
            selectedSessionID: selection.selectedSessionID,
            theme: theme,
            fontFamily: fontFamily,
            fontSize: fontSize,
            focusRequestID: focusRequestID,
            switchRequestedAt: switchRequestedAt,
            selectionChangedAt: selection.changedAt,
            clickAt: selection.pendingClickAt,
            selection: selection
        )
    }
}

private struct SessionRow: View {
    @ObservedObject var session: BanyanSession
    @ObservedObject var selection: SessionSelection
    let launchProfile: NewSessionLaunch?
    let depth: Int
    let titleOverride: String?
    let isHistory: Bool
    let isParent: Bool
    /// Whether every row in this sidebar group reserves the leading
    /// disclosure slot. Decided per group (see `sidebarSections`): when no
    /// row needs it, rows stay compact; otherwise same-depth badges align
    /// and a top-level parent can't read as its sibling's child.
    let showsDisclosureGutter: Bool
    let isCollapsed: Bool
    let hiddenChildCount: Int
    let jumpKeyLabel: String
    let onSelect: () -> Void
    let onToggleCollapse: () -> Void
    let onRevealHidden: () -> Void
    let onClose: () -> Void
    let onRestart: () -> Void
    let onRespawn: () -> Void
    let onRecover: () -> Void
    let isHandoffAvailable: Bool
    let isHandoffPending: Bool
    let onHandoff: () -> Void
    let onRemove: () -> Void
    let onToggleSuspended: () -> Void
    let onFocusTerminal: () -> Void
    let onReopenHistory: () -> Void

    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var isIssueLinkHovered = false
    @State private var isHandoffHovered = false
    @State private var isRowHovered = false
    @State private var isPointerCursorPushed = false
    @FocusState private var isRenameFocused: Bool

    private var isSelected: Bool {
        selection.selectedSessionID == session.id
    }

    /// Provider whose brand the row shows: the launch profile's when it
    /// declares an icon identity (Luna, DeepSeek-in-Codex), the detected
    /// runtime's otherwise. Drives both the icon below and the jump-key tint.
    private var brandingProvider: CodingAgentProvider? {
        NewSessionLaunch.brandingProvider(
            for: launchProfile,
            detectedProvider: session.displayAgentProvider
        )
    }

    /// Whether that brand came from the launch profile rather than the
    /// detected runtime, which decides whether the profile's own icon is drawn.
    private var isBrandedByLaunchProfile: Bool {
        launchProfile?.hasIconIdentity == true && session.displayAgentProvider != nil
    }

    /// When the handoff affordance is showing, it already occupies the row's
    /// trailing edge. The hover close button is suppressed there so it can't shift
    /// the handoff button or be clicked by accident in its place.
    private var showsHandoffButton: Bool {
        isHandoffAvailable && session.canDispatchHandoff && !isHandoffPending
    }

    var body: some View {
        HStack(spacing: 6) {
            // All rows in a group with any nesting share a fixed leading
            // slot, so same-depth badges align whether or not a given row
            // has a disclosure triangle of its own.
            if showsDisclosureGutter {
                if isParent {
                    Button(action: onToggleCollapse) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 18)
                            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    }
                    .buttonStyle(.banyanPlainLabelOnly)
                    .help(isCollapsed ? "Expand child sessions" : "Collapse child sessions")
                    .accessibilityLabel(isCollapsed ? "Expand child sessions" : "Collapse child sessions")
                    .accessibilityIdentifier(AccessibilityID.sessionRowDisclosure(session.id))
                } else {
                    Color.clear
                        .frame(width: 14, height: 18)
                }
            }

            JumpKeyBadge(label: jumpKeyLabel, provider: brandingProvider)

            // A plain-shell profile (the built-in `zsh`) matches every session
            // whose command is empty, including one that later became an agent
            // session. Only let a profile brand the row when it declares an
            // icon identity; otherwise the detected provider wins, so an agent
            // started by hand inside a shell is still recognized.
            if isBrandedByLaunchProfile, let launchProfile {
                NewSessionLaunchIcon(launch: launchProfile, size: 18)
                    .accessibilityLabel(launchProfile.label)
            } else if let provider = session.displayAgentProvider {
                AgentProviderIcon(provider: provider, size: 18, helpText: session.agentRuntimeIdentityLabel)
                    .accessibilityLabel(provider.displayName)
            } else if !session.isImportedHistory {
                ShellSessionIcon()
            }

            if session.isSuspended && !session.isImportedHistory && session.status != .closed {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 18)
                    .help("Parked — Banyan is not supervising or rendering this session. Its tmux session and agent are still running.")
                    .accessibilityLabel("Parked")
                    .accessibilityIdentifier(AccessibilityID.sessionRowSuspendedBadge(session.id))
            }

            if !session.isImportedHistory && session.status != .closed && !hidesStatusEmoji {
                Text(session.status.emoji)
                    .font(.system(size: 12))
                    .frame(width: 16, height: 18)
                    .help(session.status.label)
                    .accessibilityLabel(session.status.label)
                    .accessibilityIdentifier(AccessibilityID.sessionRowStatus(session.id))
            }

            if isRenaming {
                TextField("Session title", text: $renameDraft)
                    .textFieldStyle(.plain)
                    .font(titleFont)
                    .focused($isRenameFocused)
                    .onSubmit(commitRenameAndFocusTerminal)
                    .onExitCommand(perform: cancelRename)
                    .onChange(of: isRenameFocused) { _, isFocused in
                        if !isFocused, isRenaming {
                            commitRename()
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.sessionRowTitle(session.id))
            } else {
                titleLabel
            }

            if hiddenChildCount > 0 {
                Button(action: onRevealHidden) {
                    Text("\(hiddenChildCount)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                .buttonStyle(.banyanPlainLabelOnly)
                .help(
                    isCollapsed
                        ? "\(hiddenChildCount) hidden child sessions — click to expand"
                        : "\(hiddenChildCount) finished child sessions hidden — click to show"
                )
                .accessibilityLabel(
                    isCollapsed
                        ? "Expand \(hiddenChildCount) hidden child sessions"
                        : "Show \(hiddenChildCount) finished child sessions"
                )
            }

            Spacer(minLength: 0)

            if showsHandoffButton {
                Button {
                    onSelect()
                    onHandoff()
                } label: {
                    Text("🤝")
                        .font(.system(size: 12))
                        .frame(width: 20, height: 20)
                        .background(handoffButtonBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .scaleEffect(isHandoffHovered ? 1.06 : 1)
                        .animation(.easeOut(duration: 0.12), value: isHandoffHovered)
                }
                .buttonStyle(.banyanPlainLabelOnly)
                .onHover { isHandoffHovered = $0 }
                .onDisappear { isHandoffHovered = false }
                .help("Handoff")
                .accessibilityLabel("Handoff")
                .accessibilityIdentifier(AccessibilityID.sessionRowHandoffButton(session.id))
            }

            if isRowHovered && session.status != .closed && !showsHandoffButton {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.banyanPlainLabelOnly)
                .help("Close session")
                .accessibilityLabel("Close session")
                .accessibilityIdentifier(AccessibilityID.sessionRowCloseButton(session.id))
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .padding(.vertical, 2)
        .padding(.leading, CGFloat(depth) * 18)
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .background(rowBackground)
        .opacity(dimsRow ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover(perform: setRowHovered)
        .onChange(of: isRenaming) { _, _ in syncPointerCursor() }
        .onChange(of: selection.renameRequestID) { _, _ in
            if isSelected {
                beginRename()
            }
        }
        .onDisappear(perform: resetRowHover)
        .animation(.easeOut(duration: 0.12), value: isRowHovered)
        .simultaneousGesture(singleClickSelectGesture)
        .simultaneousGesture(doubleClickRenameGesture)
        .contextMenu {
            Button("Rename") {
                beginRename()
            }
            Divider()
            if session.status == .closed {
                Button("Reopen") {
                    onRespawn()
                }
            } else if session.needsRecovery {
                Button("Recover") {
                    onRecover()
                }
            } else {
                Button("Close") {
                    onClose()
                }
            }
            if !session.isImportedHistory && session.status != .closed {
                Button(session.isSuspended ? "Resume" : "Suspend") {
                    onToggleSuspended()
                }
                Button("Restart") {
                    onRestart()
                }
            }
            Button("Remove") {
                onRemove()
            }
        }
        .onDisappear {
            resetIssueLinkHover()
        }
        .accessibilityIdentifier(AccessibilityID.sessionRow(session.id))
    }

    private func beginRename() {
        guard !isRenaming else { return }
        onSelect()
        renameDraft = session.displayTitle
        isRenaming = true
        DispatchQueue.main.async {
            isRenameFocused = true
        }
    }

    private func commitRename() {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != session.displayTitle {
            session.mark(title: trimmed)
        }
        isRenaming = false
    }

    private func commitRenameAndFocusTerminal() {
        commitRename()
        DispatchQueue.main.async {
            onFocusTerminal()
        }
    }

    private func cancelRename() {
        isRenaming = false
    }

    private var displayTitle: String {
        titleOverride ?? session.displayTitle
    }

    private var titleFont: Font {
        Font(NSFont.systemFont(ofSize: 13, weight: isSelected ? .medium : .regular))
    }

    @ViewBuilder
    private var titleLabel: some View {
        if let titleURL = session.titleURL,
           let url = URL(string: titleURL),
           let titleLinkLabel = session.titleLinkLabel {
            HStack(spacing: 4) {
                Link(destination: url) {
                    Text(titleLinkLabel)
                        .font(titleFont)
                        .underline(isIssueLinkHovered)
                        .lineLimit(1)
                }
                .onHover(perform: setIssueLinkHovered)
                let remainder = linkedTitleRemainder(issueID: titleLinkLabel)
                if !remainder.isEmpty {
                    Text("·")
                        .font(titleFont)
                        .foregroundStyle(.secondary)
                    Text(remainder)
                        .font(titleFont)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier(AccessibilityID.sessionRowTitle(session.id))
        } else {
            Text(displayTitle)
                .font(titleFont)
                .foregroundStyle(session.isImportedHistory || session.status == .closed ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier(AccessibilityID.sessionRowTitle(session.id))
        }
    }

    private func linkedTitleRemainder(issueID: String) -> String {
        SessionTitleGenerator.linkedTitleRemainder(displayTitle: displayTitle, issueID: issueID)
    }

    private func setRowHovered(_ isHovered: Bool) {
        isRowHovered = isHovered
        syncPointerCursor()
    }

    private func resetRowHover() {
        isRowHovered = false
        syncPointerCursor()
    }

    /// A pushed cursor outranks the text field's own I-beam cursor rect, so the
    /// pointing hand has to come back off the stack while the row is renaming.
    private func syncPointerCursor() {
        let wantsPointer = isRowHovered && !isRenaming
        guard wantsPointer != isPointerCursorPushed else { return }
        isPointerCursorPushed = wantsPointer
        if wantsPointer {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    private func setIssueLinkHovered(_ isHovered: Bool) {
        guard isIssueLinkHovered != isHovered else { return }
        isIssueLinkHovered = isHovered
        if isHovered {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    private func resetIssueLinkHover() {
        guard isIssueLinkHovered else { return }
        isIssueLinkHovered = false
        NSCursor.pop()
    }

    @ViewBuilder
    private var handoffButtonBackground: some View {
        if isHandoffHovered {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.22) : Color.accentColor.opacity(0.16))
        } else {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.clear)
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
        } else if isRowHovered {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.08))
        } else {
            Color.clear
        }
    }

    /// History rows and parked sessions both recede: neither is something the
    /// user is currently working in. Selection always wins so the row the user is
    /// looking at stays legible.
    private var dimsRow: Bool {
        !isSelected && (isHistory || session.isSuspended)
    }

    /// `.running` only ever means "a bare shell prompt", which the terminal icon
    /// already says — the gear next to it just reads as a settings affordance.
    private var hidesStatusEmoji: Bool {
        session.displayAgentProvider == nil && session.status == .running
    }

    private var doubleClickRenameGesture: some Gesture {
        TapGesture(count: 2).onEnded {
            if isHistory {
                onReopenHistory()
            } else {
                beginRename()
            }
        }
    }

    private var singleClickSelectGesture: some Gesture {
        TapGesture(count: 1).onEnded {
            if !isRenaming {
                onSelect()
            }
        }
    }
}

private struct ShellSessionIcon: View {
    var body: some View {
        Image(systemName: "terminal")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .help("Shell")
            .accessibilityLabel("Shell")
    }
}

/// VS Code–style split "+" control for a project header: the primary action
/// spawns the project's last-used session kind, and the dropdown picks another
/// (remembering it). The icon reflects the remembered kind, so it becomes the
/// Claude/Codex logo once one of those is chosen.
private struct ProjectNewSessionButton: View {
    @EnvironmentObject private var store: SessionStore
    let groupID: String
    let groupTitle: String

    var body: some View {
        // Time-of-use pricing flips at most a few times a day, so a
        // once-a-minute refresh is sufficient to keep the pricing help fresh.
        // Polling here is unavoidable: there is no push source for wall-clock
        // pricing boundaries.
        TimelineView(.everyMinute) { context in
            let current = store.projectLaunch(for: groupID)
            Menu {
                ForEach(store.sessionLaunchProfiles) { launch in
                    Button {
                        store.spawnSession(inProjectGroup: groupID, launch: launch)
                    } label: {
                        Label {
                            Text(launch.label)
                        } icon: {
                            launch.menuIconImage
                        }
                    }
                }
            } label: {
                NewSessionLaunchIcon(launch: current)
            } primaryAction: {
                store.spawnSession(inProjectGroup: groupID, launch: current)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .banyanButtonHoverEffect()
            .help(peakAwareHelp(for: current, at: context.date))
            .accessibilityIdentifier(AccessibilityID.projectAddSession(groupID))
        }
    }

    private func peakAwareHelp(for launch: NewSessionLaunch, at date: Date) -> String {
        let base = "New \(launch.label) session in \(groupTitle)"
        guard let provider = launch.provider,
              let pricing = PeakPricingPolicy.helpText(for: provider, at: date)
        else {
            return base
        }
        return "\(base)\n\(pricing)"
    }
}

struct NewSessionLaunchIcon: View {
    let launch: NewSessionLaunch
    var size: CGFloat = 14

    var body: some View {
        if let customIconImage = launch.customIconImage {
            Image(nsImage: customIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else if let provider = launch.provider, launch.usesProviderIcon {
            AgentProviderIcon(provider: provider, size: size)
        } else {
            Image(systemName: launch.systemImage)
                .font(.caption)
                .frame(width: size, height: size)
        }
    }
}

private struct AgentProviderIcon: View {
    let provider: CodingAgentProvider
    var size: CGFloat = 20
    var helpText: String? = nil
    /// Closed/history rows show a past session, so peak-*now* would mislead.
    /// Pass false there; live rows and the picker leave it true.
    var showsPeakBadge: Bool = true

    var body: some View {
        if showsPeakBadge, PeakPricingPolicy.hasTimeSensitivePricing(provider) {
            // Same once-a-minute rationale as the picker: pricing boundaries
            // are wall-clock events with no push source.
            TimelineView(.everyMinute) { context in
                iconStack(at: context.date)
            }
        } else {
            iconStack(at: Date())
        }
    }

    private func iconStack(at date: Date) -> some View {
        baseIcon
            .overlay(alignment: .bottomTrailing) {
                if PeakPricingPolicy.isPeak(at: date, for: provider) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: peakDotDiameter, height: peakDotDiameter)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: 1.5)
                        )
                        .accessibilityLabel("Peak pricing")
                }
            }
            .frame(width: size, height: size)
            .help(combinedHelp(at: date))
    }

    private var peakDotDiameter: CGFloat {
        max(6, size * 0.38)
    }

    private func combinedHelp(at date: Date) -> String {
        let base = helpText ?? provider.displayName
        guard let pricing = PeakPricingPolicy.helpText(for: provider, at: date) else {
            return base
        }
        if base == pricing { return pricing }
        return "\(base)\n\(pricing)"
    }

    private var baseIcon: some View {
        Group {
            if let modelIcon = modelIcon {
                Image(nsImage: modelIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else if let templateIcon = templateIcon {
                Image(nsImage: templateIcon)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.primary)
                    .frame(width: size * 0.9, height: size * 0.9)
            } else if let appIcon = installedAppIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.9, height: size * 0.9)
            } else {
                Text(provider.badgeText)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: size * 0.9, height: size * 0.8)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                    )
            }
        }
    }

    private var modelIcon: NSImage? {
        guard let resourceName = modelIconResourceName,
              let url = Bundle.module.url(forResource: resourceName, withExtension: "svg"),
              let image = NSImage(contentsOf: url)
        else {
            return provider == .codex ? codexColorIcon : nil
        }
        image.size = NSSize(width: 20, height: 20)
        return image
    }

    private var modelIconResourceName: String? {
        switch provider {
        case .claude:
            return "ClaudeLogo"
        case .codex:
            return "ChatGPTLogo"
        case .deepseek:
            return "DeepSeekLogo"
        case .gemini:
            return "GeminiLogo"
        case .hunyuan:
            return "HunyuanLogo"
        case .minimax:
            return "MiniMaxLogo"
        case .muse:
            return "MuseLogo"
        case .opencode:
            return nil
        case .qwen:
            return "QwenLogo"
        case .xiaomiMiMo:
            return "XiaomiMiMoLogo"
        case .zai:
            return "ZAILogo"
        }
    }

    private var codexColorIcon: NSImage? {
        guard provider == .codex else { return nil }
        for path in codexColorIconPaths where FileManager.default.fileExists(atPath: path) {
            guard let image = NSImage(contentsOfFile: path),
                  let cropped = cropCodexInnerMark(from: image)
            else {
                continue
            }
            return cropped
        }
        return nil
    }

    private var templateIcon: NSImage? {
        guard provider == .codex else { return nil }
        for path in codexTemplatePaths where FileManager.default.fileExists(atPath: path) {
            guard let image = NSImage(contentsOfFile: path) else { continue }
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            return image
        }
        return nil
    }

    private func cropCodexInnerMark(from image: NSImage) -> NSImage? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let side = min(cgImage.width, cgImage.height)
        let cropSize = Int(Double(side) * 0.72)
        let originX = (cgImage.width - cropSize) / 2
        let originY = Int(Double(cgImage.height - cropSize) * 0.48)
        let cropRect = CGRect(x: originX, y: originY, width: cropSize, height: cropSize)
        guard let cropped = cgImage.cropping(to: cropRect) else {
            return nil
        }
        return NSImage(cgImage: cropped, size: NSSize(width: 20, height: 20))
    }

    private var installedAppIcon: NSImage? {
        for path in candidateAppPaths where FileManager.default.fileExists(atPath: path) {
            let icon = NSWorkspace.shared.icon(forFile: path)
            icon.size = NSSize(width: 18, height: 18)
            return icon
        }
        return nil
    }

    private var codexTemplatePaths: [String] {
        let home = NSHomeDirectory()
        return [
            "/Applications/Codex.app/Contents/Resources/codexTemplate@2x.png",
            "/Applications/Codex.app/Contents/Resources/codexTemplate.png",
            "\(home)/Applications/Codex.app/Contents/Resources/codexTemplate@2x.png",
            "\(home)/Applications/Codex.app/Contents/Resources/codexTemplate.png"
        ]
    }

    private var codexColorIconPaths: [String] {
        let home = NSHomeDirectory()
        return [
            "/Applications/Codex.app/Contents/Resources/icon-codex-dark-color.png",
            "/Applications/Codex.app/Contents/Resources/icon-codex-light.png",
            "\(home)/Applications/Codex.app/Contents/Resources/icon-codex-dark-color.png",
            "\(home)/Applications/Codex.app/Contents/Resources/icon-codex-light.png"
        ]
    }

    private var candidateAppPaths: [String] {
        let home = NSHomeDirectory()
        switch provider {
        case .claude:
            return [
                "/Applications/Claude.app",
                "\(home)/Applications/Claude.app"
            ]
        case .codex:
            return [
                "/Applications/Codex.app",
                "\(home)/Applications/Codex.app"
            ]
        case .deepseek:
            return [
                "/Applications/DeepSeek.app",
                "\(home)/Applications/DeepSeek.app"
            ]
        case .gemini, .hunyuan, .minimax, .muse, .qwen, .xiaomiMiMo, .zai:
            return []
        case .opencode:
            return [
                "/Applications/OpenCode.app",
                "\(home)/Applications/OpenCode.app"
            ]
        }
    }
}

private struct ClosedSessionHistoryView: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: BanyanSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let provider = session.agentProvider {
                    AgentProviderIcon(provider: provider, showsPeakBadge: false)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(PathDisplayName.make(path: session.cwd, homeDirectory: store.host.homeDirectory.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    reopenTrimmed()
                } label: {
                    Image(systemName: "scissors")
                }
                .buttonStyle(.banyanBorderless)
                .controlSize(.small)
                .help("Reopen with stale tool output trimmed to save context (experimental)")

                if store.isRecoveringHistoryResume(id: session.id) {
                    ProgressView()
                        .controlSize(.small)
                        .help("Finding the agent session for this working directory")
                } else {
                    Button {
                        reopenSession()
                    } label: {
                        Label("Reopen", systemImage: "arrow.uturn.forward.circle.fill")
                    }
                    .buttonStyle(.banyanBorderedProminent)
                    .controlSize(.small)
                    .help("Resume the closed Banyan session")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Group {
                if let error = store.historyResumeError(id: session.id) {
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            "Resume Unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text(error)
                        )
                        Button {
                            openShell()
                        } label: {
                            Label("Open zsh in Working Directory", systemImage: "terminal")
                        }
                        .buttonStyle(.banyanBorderedProminent)
                    }
                } else {
                    ContentUnavailableView(
                        "Closed Session",
                        systemImage: "archivebox",
                        description: Text("This history item was closed in Banyan. Reopen it to resume the agent session.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reopenSession() {
        _ = try? store.respawn(id: session.id)
    }

    private func reopenTrimmed() {
        store.respawnTrimmed(id: session.id)
    }

    private func openShell() {
        _ = try? store.openShellForClosedSession(id: session.id)
    }
}

private struct ImportedSessionHistoryView: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: BanyanSession
    @State private var preview = "Loading..."
    @State private var resumePrompt = ""
    @FocusState private var isResumePromptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let provider = session.agentProvider {
                    AgentProviderIcon(provider: provider, showsPeakBadge: false)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(PathDisplayName.make(path: session.cwd, homeDirectory: store.host.homeDirectory.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    resumeTrimmed()
                } label: {
                    Image(systemName: "scissors")
                }
                .buttonStyle(.banyanBorderless)
                .controlSize(.small)
                .help("Resume with stale tool output trimmed to save context (experimental)")

                Button {
                    resumeSession()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.banyanBorderedProminent)
                .controlSize(.small)
                .help("Resume in a Banyan session")

                Button {
                    openTranscript()
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .buttonStyle(.banyanBorderless)
                .help("Reveal transcript")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            ScrollView {
                Text(preview)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .scrollIndicators(.hidden)
            .hidesVerticalScroller()

            Divider()

            HStack(spacing: 8) {
                TextField("Message to resume...", text: $resumePrompt)
                    .textFieldStyle(.roundedBorder)
                    .focused($isResumePromptFocused)
                    .onSubmit(resumeWithPrompt)

                Button {
                    resumeWithPrompt()
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.banyanBorderless)
                .font(.system(size: 20))
                .help("Resume with message")
                .disabled(resumePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .background(.bar)
        }
        .task(id: session.id) {
            isResumePromptFocused = true
            await loadPreview()
        }
    }

    @MainActor
    private func loadPreview() async {
        guard let url = session.historyTranscriptURL,
              let provider = session.agentProvider else {
            preview = "No transcript is attached to this history item."
            return
        }
        preview = "Loading..."
        let loadedPreview = await store.transcriptPreview(from: url, provider: provider)
        guard !Task.isCancelled else { return }
        preview = loadedPreview
    }

    private func openTranscript() {
        guard let url = session.historyTranscriptURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func resumeSession() {
        _ = try? store.resumeImportedHistory(id: session.id)
    }

    private func resumeTrimmed() {
        store.resumeImportedHistoryTrimmed(id: session.id)
    }

    private func resumeWithPrompt() {
        let prompt = resumePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        resumePrompt = ""
        _ = try? store.resumeImportedHistory(id: session.id, prompt: prompt)
    }
}

private struct TerminalReconnectBanner: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: BanyanSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle")
                    .foregroundStyle(Color(nsColor: session.tone.nsColor))
                Text(statusText)
                    .font(.callout)
                Spacer()
                if store.isRecoveringWorktree(id: session.id) {
                    ProgressView()
                        .controlSize(.small)
                        .help("Recreating this session's worktree")
                } else {
                    Button {
                        if session.needsRecovery {
                            try? store.recover(id: session.id)
                        } else {
                            try? store.respawn(id: session.id)
                        }
                    } label: {
                        Label(session.needsRecovery ? "Recover" : "Attach", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.banyanBorderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier(AccessibilityID.terminalAttachButton)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Attach cannot succeed while the folder is missing, so say why
            // rather than leaving a button that only ever re-fails.
            if let failure = store.worktreeRecoveryError(id: session.id) {
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier(AccessibilityID.terminalRecoveryFailureMessage)
            }
        }
        .background(.bar)
        .accessibilityIdentifier(AccessibilityID.terminalReconnectBanner)
    }

    private var statusText: String {
        if store.isRecoveringWorktree(id: session.id) {
            return "Recreating this session's worktree…"
        }
        if session.needsRecovery {
            return "Session needs recovery after restart"
        }
        return "Session is detached"
    }
}

/// Shown over the frozen pane of a parked session. Nothing was torn down, so the
/// only thing on offer is putting it back in the working set.
private struct SuspendedSessionBanner: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: BanyanSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Session is parked")
                    .font(.callout)
                Text("Banyan stopped supervising and rendering it. Its tmux session and any agent inside are still running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                try? store.resume(id: session.id)
            } label: {
                Label("Resume", systemImage: "play")
            }
            .buttonStyle(.banyanBorderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.terminalResumeButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier(AccessibilityID.terminalSuspendedBanner)
    }
}

// MARK: - Jump overlay badge

private struct JumpKeyBadge: View {
    let label: String
    let provider: CodingAgentProvider?

    private var tint: Color {
        provider?.brandTint ?? .secondary
    }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint)
            .frame(width: Self.badgeWidth(for: label), height: 16)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(tint.opacity(0.14))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(tint.opacity(0.32), lineWidth: 0.5)
                    )
            )
    }

    private static func badgeWidth(for label: String) -> CGFloat {
        CGFloat(12 + 6 * max(label.count, 1))
    }
}
