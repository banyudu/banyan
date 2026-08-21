enum AccessibilityID {
    static let root = "banyan.root"
    static let sidebar = "banyan.sidebar"
    static let sidebarList = "banyan.sidebar.list"
    static let sidebarSearchField = "banyan.sidebar.search"
    static let sidebarFooter = "banyan.sidebar.footer"
    static let detail = "banyan.detail"
    static let emptyDetail = "banyan.detail.empty"
    static let linearIssuePanel = "banyan.linear.panel"
    static let linearIssueRefreshButton = "banyan.linear.refresh"
    static let linearIssueOpenButton = "banyan.linear.open"
    static let linearIssueStatusPicker = "banyan.linear.status"
    static let githubIssuePanel = "banyan.github-issue.panel"
    static let githubIssueRefreshButton = "banyan.github-issue.refresh"
    static let githubIssueOpenButton = "banyan.github-issue.open"
    static let terminal = "banyan.terminal"
    static let terminalReconnectBanner = "banyan.terminal.reconnect-banner"
    static let terminalAttachButton = "banyan.terminal.reconnect-banner.attach"
    static let toolbarAddSession = "banyan.toolbar.add-session"
    static let toolbarPreferences = "banyan.toolbar.preferences"
    static let toolbarLogo = "banyan.toolbar.logo"
    static let toolbarContext = "banyan.toolbar.context"
    static let toolbarLinearLink = "banyan.toolbar.linear-link"
    static let toolbarPullRequestLink = "banyan.toolbar.pull-request-link"
    static let toolbarUpdate = "banyan.toolbar.update"
    static let pullRequestPreviewPanel = "banyan.github-pr.panel"
    static let pullRequestPreviewRefreshButton = "banyan.github-pr.refresh"
    static let pullRequestPreviewOpenButton = "banyan.github-pr.open"
    static let pullRequestPreviewCloseButton = "banyan.github-pr.close"
    static let sidebarAddSession = "banyan.sidebar.add-session"
    static let sidebarOptions = "banyan.sidebar.options"
    static let sidebarCloseSelected = "banyan.sidebar.close-selected"
    static let sidebarPendingHandoffJobs = "banyan.sidebar.pending-handoff-jobs"
    static let sidebarModePicker = "banyan.sidebar.mode"
    static let linearIssueList = "banyan.sidebar.linear-list"
    static let linearIssueSearchField = "banyan.sidebar.linear-search"
    static let linearIssueStateFilterMenu = "banyan.sidebar.linear-state-filter"
    static let linearIssueSortMenu = "banyan.sidebar.linear-sort"
    static let linearIssueListRefreshButton = "banyan.sidebar.linear-refresh"
    static let linearIssueStartButton = "banyan.sidebar.linear-start"
    static let addSessionSheet = "banyan.sheet.add-session"
    static let preferencesSheet = "banyan.sheet.preferences"

    static func projectAddSession(_ groupID: String) -> String {
        "banyan.sidebar.project.\(groupID).add-session"
    }

    static func sessionRow(_ id: String) -> String {
        "banyan.sidebar.session-row.\(id)"
    }

    static func sessionRowTitle(_ id: String) -> String {
        "banyan.sidebar.session-row.\(id).title"
    }

    static func sessionRowStatus(_ id: String) -> String {
        "banyan.sidebar.session-row.\(id).status"
    }

    static func sessionRowHandoffButton(_ id: String) -> String {
        "banyan.sidebar.session-row.\(id).handoff"
    }

    static func sessionRowCloseButton(_ id: String) -> String {
        "banyan.sidebar.session-row.\(id).close"
    }
}
