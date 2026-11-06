import AppKit
import BanyanCore
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject private var updater: AppUpdater
    let selection: SessionSelection
    // Retain the window's map without observing every viewport change here.
    // Badges, the open palette and focused menu commands observe it locally.
    @State var sessionJumpShortcuts = SessionJumpShortcuts()
    @State private var showingPreferences = false
    @State var showingCommandPalette = false
    @State var commandPaletteProjects: [CommandPaletteProject] = []
    @State var commandModifierHeld = false
    @State var codexHandoffSession: TerminalSession?
    @State var reparentSession: BanyanSession?
    @State var draggingSidebarSessionID: String?

    init(selection: SessionSelection) {
        self.selection = selection
    }

    @State var linearIssueFilterText = ""
    @State var selectedLinearIssueStateIDs: Set<String>?
    @State var draftLinearIssueStateIDs: Set<String>?
    @State var isLinearIssueStateFilterPresented = false
    @State var linearIssueSortOption: LinearIssueSortOption = .defaultOrder
    @FocusState var linearFocusTarget: LinearFocusTarget?

    @FocusState var isSidebarSearchFocused: Bool

    var body: some View {
        let _ = EnergyTrace.count("content.body")
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 343, ideal: 429, max: 600)
        } detail: {
            detail
        }
        // The default titlebar background over the detail column starts 2pt
        // left of the split divider, so it overlapped the sidebar. Without it,
        // the detail column's own background fills the titlebar and meets the
        // divider exactly.
        .toolbarBackground(.hidden, for: .windowToolbar)
        .task { await store.refreshWorkOverview() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.scheduleWorkOverviewRefresh()
        }
        .onReceive(sessionJumpShortcuts.commandModifierChanges) { held in
            commandModifierHeld = held
        }
        .onOpenURL { url in
            guard let id = PuckSessionLink.sessionID(from: url) else { return }
            store.openPuckSession(id: id)
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
            // With a principal item, the actions below are laid out right after
            // the centered title instead of at the trailing edge. A Spacer item
            // becomes a flexible toolbar space that pushes them back.
            ToolbarItem(placement: .primaryAction) {
                Spacer()
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
        .sheet(isPresented: $store.isPuckCleanupPresented) {
            PuckCleanupSheet()
                .environmentObject(store)
        }
        .sheet(item: $codexHandoffSession, onDismiss: { store.focusSelectedTerminal() }) { session in
            CodexTUIHandoffView(store: store, session: session)
        }
        .sheet(item: $reparentSession) { session in
            SessionParentPicker(session: session,
                loadTargets: { store.reparentTargets(for: session.id) },
                move: { try store.reparent(id: session.id, parentSessionID: $0) })
        }
        .onChange(of: store.commandPaletteRequestID) {
            commandPaletteProjects = []
            showingCommandPalette = true
        }
        .alert(Text(closeConfirmationTitle), isPresented: closeConfirmationBinding) {
            closeConfirmationButtons
        } message: {
            Text(store.pendingCloseMessage)
        }
        .alert("Conversation visibility unchanged", isPresented: Binding(
            get: { store.backgroundPresentationError != nil },
            set: { if !$0 { store.backgroundPresentationError = nil } }
        )) { Button("OK", role: .cancel) { store.backgroundPresentationError = nil } } message: {
            Text(store.backgroundPresentationError ?? "")
        }
        .alert("Session remains open", isPresented: Binding(
            get: { store.pauseCloseError != nil },
            set: { if !$0 { store.pauseCloseError = nil } }
        )) {
            Button("OK", role: .cancel) { store.pauseCloseError = nil }
            if store.pauseCloseRetrySessionID != nil {
                Button("Retry Pause and Close", role: .destructive) { store.retryPauseAndClose() }
            }
        } message: {
            Text(store.pauseCloseError ?? "")
        }
        .alert("Handoff", isPresented: handoffNoticeBinding) {
            Button("OK") {
                store.handoffNotice = nil
            }
        } message: {
            Text(store.handoffNotice ?? "")
        }
        .alert("Puck session error", isPresented: puckSessionErrorBinding) {
            Button("OK") { store.puckSessionError = nil }
        } message: {
            Text(store.puckSessionError ?? "")
        }
        .alert("Codex session error", isPresented: Binding(
            get: { store.codexSessionError != nil },
            set: { if !$0 { store.codexSessionError = nil } }
        )) {
            Button("OK") { store.codexSessionError = nil }
        } message: {
            Text(store.codexSessionError ?? "")
        }
        .background(WindowRestorationConfigurator(shortcuts: sessionJumpShortcuts))
        .focusedSceneObject(sessionJumpShortcuts)
        .onChange(of: store.sessionShortcutConfiguration.visibleRowShortcuts, initial: true) { _, enabled in
            sessionJumpShortcuts.setRollingEnabled(enabled)
        }
        .preferredColorScheme(store.terminalTheme.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("AppleInterfaceThemeChangedNotification"))) { _ in
            store.refreshTerminalAppearance()
        }
        .overlay {
            if showingCommandPalette {
                SessionShortcutMapObserver(shortcuts: sessionJumpShortcuts) {
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
                    .task(id: store.commandPaletteRequestID) {
                        let projects = await store.commandPaletteProjects()
                        guard !Task.isCancelled else { return }
                        commandPaletteProjects = projects
                    }
                }
            }
        }
        .accessibilityIdentifier(AccessibilityID.root)
    }
}
