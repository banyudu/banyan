import AppKit
import BanyanCore
import Combine
import SwiftUI
import UniformTypeIdentifiers

extension ContentView {
    var linearSidebar: some View {
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
}
