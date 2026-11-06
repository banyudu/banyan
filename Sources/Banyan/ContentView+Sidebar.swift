import AppKit
import BanyanCore
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension ContentView {
    var sidebar: some View {
        VStack(spacing: 0) {
            switch store.sidebarMode {
            case .sessions:
                sessionsSidebar
            case .work:
                WorkSidebarView(client: WorkitCommandOverviewClient(host: store.host),
                    sessionIDs: Set(store.sessions.filter { $0.status != .closed }.map(\.id)),
                    backgroundSessionIDs: store.backgroundedSessionIDs,
                    openSession: { store.userSelect(id: $0) })
                Divider()
                HStack { Spacer(); sidebarModeSwitcher }.padding(10)
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

    /// A Menu rather than a menu-style Picker. The Picker's pop-up button is
    /// measured on the window's first layout, before it has a title, so
    /// `.fixedSize()` pinned it at ~24pt and the search field beside it took the
    /// rest, leaving only a sliver of "Sessions". SwiftUI measures a Menu's
    /// label itself, so the switcher always fits the current mode's name.
    var sidebarModeSwitcher: some View {
        Menu {
            Button("Close verified sessions") {
                _ = try? store.closeVerifiedWorkflows()
            }
            .disabled(store.verifiedWorkflowSessionIDs.isEmpty)
            Divider()
            Picker("Sidebar", selection: $store.sidebarMode) {
                ForEach(SidebarMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(store.sidebarMode.label)
        }
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier(AccessibilityID.sidebarModePicker)
    }

    private var sessionsSidebar: some View {
        let groups = store.unifiedSidebarGroups
        let sessionIDs = groups.flatMap(\.items).map(\.id)
        return VStack(spacing: 0) {
            ScrollViewReader { proxy in
                List {
                    sidebarSections(groups)
                }
                .sessionJumpShortcutViewport(shortcuts: sessionJumpShortcuts, sessionIDs: sessionIDs)
                .listStyle(.sidebar)
                .contentMargins(.trailing, 4, for: .scrollContent)
                .scrollIndicators(.hidden)
                .hidesVerticalScroller()
                .accessibilityIdentifier(AccessibilityID.sidebarList)
                .sessionSidebarReveal(selection: selection, sessionIDs: sessionIDs, proxy: proxy)
            }

            Spacer(minLength: 0)

            if store.showsPuckBackgroundEntry {
                Divider()
                PuckBackgroundSessionsEntry(store: store)
            }

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
                    Picker("Show", selection: $store.sidebarScope) {
                        ForEach(SessionSidebarScope.allCases, id: \.self) { scope in
                            Text(scope.label).tag(scope)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    if store.sidebarScope == .focus, store.hiddenSessionCount > 0 {
                        Text(store.hiddenSessionCount == 1
                            ? "1 session hidden"
                            : "\(store.hiddenSessionCount) sessions hidden")
                    }
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
                .help(store.sidebarScope == .focus
                    ? "Sidebar options — Focus shows only actionable work"
                    : "Sidebar options — All sessions")

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

    @ViewBuilder
    func sidebarSections(
        _ groups: [SidebarSessionGroup]
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
            // The project chip is the section's first row, not its header. This
            // binary links against the macOS 14 SDK, where sidebar section
            // headers are collapsible: hovering one drew the system's collapse
            // chevron just outside the chip, and `.collapsible(false)` is
            // ignored there. A headerless section gets no collapse control.
            Section {
                sidebarGroupHeader(group, isStatic: isStatic, isFirst: group.id == firstGroupID)

                if isStatic {
                    ForEach(group.items) { item in
                        sidebarRow(
                            item,
                            groupID: group.id,
                            allowsDragSort: false,
                            isHistory: item.isHistory,
                            showsDisclosureGutter: showsDisclosureGutter,
                            jumpKeyLabel: ""
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
                            jumpKeyLabel: ""
                        )
                    }
                }
            }
            .listSectionSeparator(isStatic ? .visible : .hidden, edges: .top)
        }
    }

    private func sidebarGroupHeader(
        _ group: SidebarSessionGroup,
        isStatic: Bool,
        isFirst: Bool
    ) -> some View {
        HStack(spacing: 4) {
            Text(group.title)
                .font(.caption)
                .foregroundStyle(isStatic ? .tertiary : .secondary)
                .lineLimit(1)

            if !isStatic {
                Spacer(minLength: 4)

                ProjectNewSessionButton(
                    groupID: group.id,
                    groupTitle: group.title
                )
            }
        }
        // Static headers have no button; keep every chip the same height.
        .frame(minHeight: 20)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A rounded chip rather than a full-bleed band. The window background
        // is darker than the sidebar in dark mode and lighter in light mode, so
        // the chip never reads as a hovered row.
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .accessibilityAddTraits(.isHeader)
        // Only the first project gets extra top breathing room under the
        // mode-picker divider; adding it to every header widened the gaps
        // between projects. The history/search header gets a touch more space
        // so it reads as a separator above the active rows. This is padding
        // rather than a row inset: a sidebar row applies its vertical insets to
        // both edges.
        .padding(.top, isFirst ? 4 : (isStatic ? 8 : 0))
        .padding(.bottom, 2)
        // Match the session rows' leading inset so the chip lines up with
        // their highlights, while letting both use the sidebar's trailing edge.
        .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 0))
    }

    private func sidebarRow(
        _ item: SidebarSessionItem,
        groupID: String,
        allowsDragSort: Bool,
        isHistory: Bool,
        showsDisclosureGutter: Bool,
        jumpKeyLabel: String
    ) -> some View {
        let supportsSessionCost = item.session.agentProvider == .codex
            || item.session.agentProvider == .claude

        return SessionRow(
            session: item.session,
            selection: selection,
            launchProfile: store.sessionLaunchProfile(for: item.session),
            depth: item.depth,
            titleOverride: item.titleOverride,
            isHistory: isHistory,
            isParent: item.isParent,
            showsDisclosureGutter: showsDisclosureGutter,
            isFolded: item.isFolded,
            jumpKeyLabel: jumpKeyLabel,
            jumpShortcuts: sessionJumpShortcuts,
            workState: store.workState(for: item.id),
            actionOwner: ObjectIdentifier(store),
            openWorkSession: { store.userSelect(id: $0) },
            onSelect: {
                store.userSelect(id: item.session.id)
            },
            onToggleFold: {
                store.toggleChildrenFolded(for: item.session.id)
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
            onCodexRemoteHandoff: {
                codexHandoffSession = item.session as? TerminalSession
            },
            onRemove: {
                try? store.remove(id: item.session.id)
            },
            onChooseParent: { reparentSession = item.session },
            moveOptions: item.moveOptions,
            onMove: { command in
                store.moveSidebarSession(item.session.id, command: command, in: groupID)
            },
            onToggleSuspended: {
                try? store.toggleSuspended(id: item.session.id)
            },
            onSetFrozen: { frozen in
                Task {
                    do {
                        if frozen { try await store.freezeAgent(id: item.session.id) }
                        else { try store.unfreezeAgent(id: item.session.id) }
                    } catch {
                        (item.session as? TerminalSession)?.freezeError = error.localizedDescription
                    }
                }
            },
            onSetDeepSuspended: { suspended in
                Task {
                    do {
                        if suspended { try await store.deepSuspendAgent(id: item.session.id) }
                        else { try store.deepResumeAgent(id: item.session.id) }
                    } catch { (item.session as? TerminalSession)?.deepSuspendError = error.localizedDescription }
                }
            },
            onFocusTerminal: {
                store.focusSelectedTerminal()
            },
            onReopenHistory: {
                reopenHistory(item)
            },
            sessionCost: supportsSessionCost
                ? SessionCostAccess(
                    source: { store.sessionCostTranscriptSource(for: item.session) },
                    estimate: { source in await store.sessionCostEstimate(for: source) }
                )
                : nil
        )
        .equatable()
        .id(item.session.id)
        .tag(item.session.id)
        .sessionJumpShortcutRow(id: item.id)
        .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 0))
        .modifier(SidebarDragSortModifier(
            sessionID: item.session.id,
            isEnabled: allowsDragSort,
            draggingSessionID: $draggingSidebarSessionID,
            canMove: { sourceID, targetID, zone in
                store.canMoveSidebarSession(
                    sourceID,
                    command: zone.command(targetID: targetID),
                    in: groupID
                )
            },
            onMove: { sourceID, targetID, zone in
                store.moveSidebarSession(
                    sourceID,
                    command: zone.command(targetID: targetID),
                    in: groupID
                )
            }
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
}
