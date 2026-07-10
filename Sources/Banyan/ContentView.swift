import AppKit
import BanyanCore
import SwiftUI
import UniformTypeIdentifiers

private let sidebarTitlebarHeaderHeight: CGFloat = 78
private let sidebarTitlebarHeaderTopPadding: CGFloat = 30

struct ContentView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var showingPreferences = false
    @State private var draggingSidebarSessionID: String?
    @State private var linearIssueFilterText = ""
    @State private var selectedLinearIssueStateIDs: Set<String>?

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
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
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
            store.refreshImportedHistory(spawnDefaultIfEmpty: true)
            store.startControlServer()
            store.startSupervisor()
            store.startHistoryImport()
        }
        .alert("Close parent session?", isPresented: closeConfirmationBinding) {
            Button("Cancel", role: .cancel) {}
            Button("Detach and Close", role: .destructive) {
                store.confirmPendingClose()
            }
        } message: {
            Text(closeConfirmationMessage)
        }
        .background(WindowTitleConfigurator(trigger: titlebarConfigurationTrigger))
        .preferredColorScheme(store.terminalTheme.colorScheme)
        .accessibilityIdentifier(AccessibilityID.root)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarModeHeader

            switch store.sidebarMode {
            case .sessions:
                sessionsSidebar
            case .linear:
                linearSidebar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(edges: .top)
        .accessibilityIdentifier(AccessibilityID.sidebar)
    }

    private var sidebarModeHeader: some View {
        VStack(spacing: 0) {
            Picker("Sidebar", selection: $store.sidebarMode) {
                ForEach(SidebarMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .padding(.top, sidebarTitlebarHeaderTopPadding)
            .accessibilityIdentifier(AccessibilityID.sidebarModePicker)

            Divider()
        }
        .frame(height: sidebarTitlebarHeaderHeight, alignment: .bottom)
        .background(.regularMaterial)
    }

    private var sessionsSidebar: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedSessionID) {
                sidebarSections(store.sessionSidebarGroups, allowsMove: true)
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier(AccessibilityID.sidebarList)

            Spacer(minLength: 0)

            if let historyGroup = store.historySidebarGroup {
                Divider()
                List(selection: $store.selectedSessionID) {
                    sidebarSections([historyGroup], allowsMove: false)
                }
                .listStyle(.sidebar)
                .frame(height: historyListHeight(itemCount: historyGroup.items.count))
                .accessibilityIdentifier(AccessibilityID.sidebarHistoryList)
            }

            HStack {
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
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .accessibilityIdentifier(AccessibilityID.sidebarOptions)
                .help("Sidebar options")

                Spacer()

                if let selected = store.selectedSession, selected.status != .closed {
                    Button {
                        store.requestClose(id: selected.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityIdentifier(AccessibilityID.sidebarCloseSelected)
                    .help("Close selected session")
                }
            }
            .buttonStyle(.borderless)
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

            HStack {
                Button {
                    store.refreshLinearIssueList()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityIdentifier(AccessibilityID.linearIssueListRefreshButton)
                .help("Refresh Linear issues")

                Spacer()

                Button {
                    store.startSelectedLinearListIssueSession()
                } label: {
                    Label("Start", systemImage: "play.fill")
                }
                .disabled(store.selectedLinearListIssueID == nil || store.linearIssueListLoadState.isStarting)
                .accessibilityIdentifier(AccessibilityID.linearIssueStartButton)
                .help("Start Banyan session for selected issue")
            }
            .buttonStyle(.borderless)
            .padding(12)
            .accessibilityIdentifier(AccessibilityID.sidebarFooter)
        }
    }

    private var linearIssueFilterHeader: some View {
        VStack(spacing: 6) {
            linearIssueSearchField
            linearIssueStateFilterMenu
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
                .accessibilityIdentifier(AccessibilityID.linearIssueSearchField)

            if !linearIssueFilterText.isEmpty {
                Button {
                    linearIssueFilterText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }

    private var linearIssueStateFilterMenu: some View {
        HStack(spacing: 8) {
            Menu {
                if availableLinearIssueStates.isEmpty {
                    Text("No states loaded")
                } else {
                    ForEach(availableLinearIssueStates) { state in
                        Toggle(isOn: linearIssueStateFilterBinding(for: state)) {
                            Label {
                                Text(state.name)
                            } icon: {
                                Circle()
                                    .fill(Color.linearHex(state.color))
                            }
                        }
                    }

                    Divider()

                    Button("Use Default States") {
                        selectedLinearIssueStateIDs = nil
                    }

                    Button("Show All States") {
                        selectedLinearIssueStateIDs = Set(allLinearIssueStatesForFiltering.map(\.id))
                    }
                }
            } label: {
                Label(linearIssueStateFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .accessibilityIdentifier(AccessibilityID.linearIssueStateFilterMenu)
            .help("Filter Linear issues by state")

            Spacer(minLength: 0)
        }
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
                store.refreshLinearIssueListIfNeeded()
            }
        case let .failed(message):
            VStack(spacing: 10) {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    store.refreshLinearIssueList()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
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
                    description: Text("Assigned Todo and In Progress issues will appear here.")
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
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(issues) { issue in
                        LinearIssueRow(
                            issue: issue,
                            isSelected: store.selectedLinearListIssueID == issue.identifier,
                            isStarting: store.linearIssueListLoadState.isStarting(issue.identifier),
                            onSelect: {
                                store.selectedLinearListIssueID = issue.identifier
                            },
                            onStart: {
                                store.startLinearIssueSession(issue.identifier)
                            }
                        )
                        .padding(.horizontal, 6)
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.visible)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .clipped()
            .accessibilityIdentifier(AccessibilityID.linearIssueList)
        }
    }

    private var filteredLinearIssues: [LinearIssueSummary] {
        let tokens = linearIssueFilterText
            .split(whereSeparator: \.isWhitespace)
            .map { String($0) }
        let visibleStateIDs = activeLinearIssueStateIDs

        return store.linearIssues.filter { issue in
            let matchesState = availableLinearIssueStates.isEmpty || visibleStateIDs.contains(issue.state.id)
            let matchesText = tokens.isEmpty || issue.matchesFilterTokens(tokens)
            return matchesState && matchesText
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
        Set(allLinearIssueStatesForFiltering.filter(\.isDefaultVisibleInLinearList).map(\.id))
    }

    private var activeLinearIssueStateIDs: Set<String> {
        selectedLinearIssueStateIDs ?? defaultLinearIssueStateIDs
    }

    private var linearIssueStateFilterLabel: String {
        guard !availableLinearIssueStates.isEmpty else { return "States" }
        let visibleCount = availableLinearIssueStates.filter { state in
            !activeLinearIssueStateIDs.intersection(linearIssueStateIDs(matching: state)).isEmpty
        }.count
        if selectedLinearIssueStateIDs == nil {
            return "Default states"
        }
        if visibleCount == availableLinearIssueStates.count {
            return "All states"
        }
        return "\(visibleCount) states"
    }

    private func linearIssueStateFilterBinding(for state: LinearWorkflowState) -> Binding<Bool> {
        Binding {
            !activeLinearIssueStateIDs.intersection(linearIssueStateIDs(matching: state)).isEmpty
        } set: { isSelected in
            var selectedIDs = activeLinearIssueStateIDs
            let matchingIDs = linearIssueStateIDs(matching: state)
            if isSelected {
                selectedIDs.formUnion(matchingIDs)
            } else {
                selectedIDs.subtract(matchingIDs)
            }
            selectedLinearIssueStateIDs = selectedIDs
        }
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
    private func sidebarSections(_ groups: [SidebarSessionGroup], allowsMove: Bool) -> some View {
        ForEach(groups) { group in
            Section {
                if allowsMove {
                    ForEach(group.items) { item in
                        sidebarRow(item, groupID: group.id, allowsDragSort: true)
                    }
                    .onMove { source, destination in
                        store.moveSidebarSessions(in: group.id, from: source, to: destination)
                    }
                } else {
                    ForEach(group.items) { item in
                        sidebarRow(item, groupID: group.id, allowsDragSort: false)
                    }
                }
            } header: {
                Text(group.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private func sidebarRow(_ item: SidebarSessionItem, groupID: String, allowsDragSort: Bool) -> some View {
        SessionRow(
            session: item.session,
            depth: item.depth,
            titleOverride: item.titleOverride,
            isSelected: store.selectedSessionID == item.session.id,
            onSelect: {
                store.select(id: item.session.id)
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
            onRemove: {
                try? store.remove(id: item.session.id)
            }
        )
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

    private func historyListHeight(itemCount: Int) -> CGFloat {
        min(CGFloat(itemCount) * 31 + 36, 320)
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
        return "Closing \(session.displayTitle) will detach its child sessions to the same level as this parent session."
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
            return "Preview GitHub pull request (Cmd-G)"
        }
        if let number = context.pullRequestNumber {
            return "Preview GitHub pull request #\(number) (Cmd-G)"
        }
        if let title = context.pullRequestTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return "Preview GitHub pull request: \(title)"
        }
        return "Preview GitHub pull request (Cmd-G)"
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
        if let session = store.selectedSession {
            HStack(spacing: 0) {
                selectedSessionDetail(session)

                if store.isPullRequestPreviewPresented,
                   let context = store.selectedPullRequestPreviewContext,
                   session.status != .closed {
                    Divider()
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
                } else if let context = store.selectedContextInfo,
                          context.linearIssueID?.isEmpty == false,
                          session.status != .closed {
                    Divider()
                    LinearIssuePanel(
                        context: context,
                        issue: store.selectedLinearIssueDetails,
                        loadState: store.selectedLinearIssueLoadState,
                        onRefresh: {
                            store.refreshSelectedLinearIssue(force: true)
                        },
                        onOpen: store.openSelectedLinearIssue,
                        onChangeState: store.updateSelectedLinearIssueState
                    )
                    .onAppear {
                        store.refreshSelectedLinearIssue(force: true)
                    }
                }
            }
            .accessibilityIdentifier(AccessibilityID.detail)
        } else {
            ContentUnavailableView(
                "No Session Selected",
                systemImage: "terminal",
                description: Text("Spawn a session from the toolbar or with banyanctl.")
            )
            .accessibilityIdentifier(AccessibilityID.emptyDetail)
        }
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

    @ViewBuilder
    private func selectedSessionDetail(_ session: BanyanSession) -> some View {
        if session.status == .closed {
            ClosedSessionHistoryView(session: session)
        } else if session.isImportedHistory {
            ImportedSessionHistoryView(session: session)
        } else {
            VStack(spacing: 0) {
                if session.needsManualAttach {
                    TerminalReconnectBanner(session: session)
                    Divider()
                }
                TerminalHostView(
                    session: session,
                    theme: store.terminalTheme,
                    fontFamily: store.terminalFontFamily,
                    fontSize: store.terminalFontSize,
                    focusRequestID: store.terminalFocusRequestID
                )
                    .ignoresSafeArea(edges: .bottom)
            }
        }
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
    let isStarting: Bool
    let onSelect: () -> Void
    let onStart: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(issue.identifier)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    statusPill
                    Spacer(minLength: 0)
                }

                Text(issue.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 6) {
                    if let projectName = issue.projectName {
                        Text(projectName)
                    }
                    if let priority = issue.priority, priority > 0 {
                        Text("P\(priority)")
                    }
                    if let cycleName = issue.cycleName {
                        Text(cycleName)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()

            Button(action: onStart) {
                if isStarting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "play.fill")
                }
            }
            .buttonStyle(.borderless)
            .frame(width: 24, height: 24)
            .disabled(isStarting)
            .help("Start Banyan session")
        }
        .frame(height: 52)
        .padding(.horizontal, 8)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
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
                .fill(Color.linearHex(issue.state.color))
                .frame(width: 6, height: 6)
            Text(issue.state.name)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: 92, alignment: .leading)
        .clipped()
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
                    .underline(isHovered)
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
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .onHover(perform: setHovered)
        .onDisappear(perform: resetHover)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var sanitizedSecondary: String? {
        let trimmed = secondary?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func setHovered(_ hovered: Bool) {
        guard isEnabled, isHovered != hovered else { return }
        isHovered = hovered
        if hovered {
            NSCursor.pointingHand.push()
        } else {
            NSCursor.pop()
        }
    }

    private func resetHover() {
        guard isHovered else { return }
        isHovered = false
        NSCursor.pop()
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

private struct SessionRow: View {
    @ObservedObject var session: BanyanSession
    let depth: Int
    let titleOverride: String?
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    let onRestart: () -> Void
    let onRespawn: () -> Void
    let onRemove: () -> Void

    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var isIssueLinkHovered = false
    @FocusState private var isRenameFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if let provider = session.agentProvider {
                AgentProviderIcon(provider: provider)
                    .accessibilityLabel(provider.displayName)
            }

            if !session.isImportedHistory && session.status != .closed {
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
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .focused($isRenameFocused)
                    .onSubmit(commitRename)
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

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .padding(.vertical, 2)
        .padding(.leading, 4 + CGFloat(depth) * 18)
        .padding(.trailing, 4)
        .background(rowBackground)
        .contentShape(Rectangle())
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
            } else {
                Button("Close") {
                    onClose()
                }
            }
            if !session.isImportedHistory && session.status != .closed {
                Button("Restart") {
                    onRestart()
                }
            }
            Button("Remove") {
                onRemove()
            }
        }
        .onDisappear(perform: resetIssueLinkHover)
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

    private func cancelRename() {
        isRenaming = false
    }

    private var displayTitle: String {
        titleOverride ?? session.displayTitle
    }

    @ViewBuilder
    private var titleLabel: some View {
        if let titleURL = session.titleURL,
           let url = URL(string: titleURL),
           let titleLinkLabel = session.titleLinkLabel {
            HStack(spacing: 4) {
                Link(destination: url) {
                    Text(titleLinkLabel)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .underline(isIssueLinkHovered)
                        .lineLimit(1)
                }
                .onHover(perform: setIssueLinkHovered)
                let remainder = linkedTitleRemainder(issueID: titleLinkLabel)
                if !remainder.isEmpty {
                    Text(remainder)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier(AccessibilityID.sessionRowTitle(session.id))
        } else {
            Text(displayTitle)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(session.isImportedHistory || session.status == .closed ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier(AccessibilityID.sessionRowTitle(session.id))
        }
    }

    private func linkedTitleRemainder(issueID: String) -> String {
        let parts = displayTitle.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let firstToken = parts.first,
              firstToken.caseInsensitiveCompare(issueID) == .orderedSame else {
            return displayTitle
        }
        return parts.count > 1 ? String(parts[1]) : ""
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
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
        } else {
            Color.clear
        }
    }

    private var doubleClickRenameGesture: some Gesture {
        TapGesture(count: 2).onEnded {
            beginRename()
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

private struct AgentProviderIcon: View {
    let provider: CodingAgentProvider

    var body: some View {
        Group {
            if let modelIcon = modelIcon {
                Image(nsImage: modelIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 20, height: 20)
            } else if let templateIcon = templateIcon {
                Image(nsImage: templateIcon)
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.primary)
                    .frame(width: 18, height: 18)
            } else if let appIcon = installedAppIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            } else {
                Text(provider.badgeText)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                    )
            }
        }
        .frame(width: 20, height: 20)
        .help(provider.displayName)
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
        case .minimax:
            return "MiniMaxLogo"
        case .opencode:
            return nil
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
        case .gemini, .minimax, .xiaomiMiMo, .zai:
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
                    AgentProviderIcon(provider: provider)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(session.cwd)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    reopenSession()
                } label: {
                    Label("Reopen", systemImage: "arrow.uturn.forward.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Reopen the closed Banyan session")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            ContentUnavailableView(
                "Closed Session",
                systemImage: "archivebox",
                description: Text("This history item was closed in Banyan. Reopen it to attach the terminal again.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reopenSession() {
        _ = try? store.respawn(id: session.id)
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
                    AgentProviderIcon(provider: provider)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(session.cwd)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    resumeSession()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Resume in a Banyan session")

                Button {
                    openTranscript()
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .buttonStyle(.borderless)
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
                .buttonStyle(.borderless)
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
        let loadedPreview = await Task.detached(priority: .utility) {
            AgentSessionHistoryImporter.transcriptPreview(from: url, provider: provider)
        }.value
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
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(Color(nsColor: session.tone.nsColor))
            Text("Session is detached")
                .font(.callout)
            Spacer()
            Button {
                try? store.respawn(id: session.id)
            } label: {
                Label("Attach", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.terminalAttachButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier(AccessibilityID.terminalReconnectBanner)
    }
}
