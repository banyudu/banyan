enum AccessibilityID {
    static let root = "banyan.root"
    static let sidebar = "banyan.sidebar"
    static let sidebarList = "banyan.sidebar.list"
    static let sidebarHistoryList = "banyan.sidebar.history-list"
    static let sidebarFooter = "banyan.sidebar.footer"
    static let detail = "banyan.detail"
    static let emptyDetail = "banyan.detail.empty"
    static let linearIssuePanel = "banyan.linear.panel"
    static let linearIssueRefreshButton = "banyan.linear.refresh"
    static let linearIssueOpenButton = "banyan.linear.open"
    static let terminal = "banyan.terminal"
    static let terminalReconnectBanner = "banyan.terminal.reconnect-banner"
    static let terminalAttachButton = "banyan.terminal.reconnect-banner.attach"
    static let toolbarAddSession = "banyan.toolbar.add-session"
    static let toolbarPreferences = "banyan.toolbar.preferences"
    static let toolbarLogo = "banyan.toolbar.logo"
    static let toolbarContext = "banyan.toolbar.context"
    static let toolbarLinearLink = "banyan.toolbar.linear-link"
    static let toolbarPullRequestLink = "banyan.toolbar.pull-request-link"
    static let sidebarAddSession = "banyan.sidebar.add-session"
    static let sidebarOptions = "banyan.sidebar.options"
    static let sidebarCloseSelected = "banyan.sidebar.close-selected"
    static let sidebarModePicker = "banyan.sidebar.mode"
    static let linearIssueList = "banyan.sidebar.linear-list"
    static let linearIssueListRefreshButton = "banyan.sidebar.linear-refresh"
    static let linearIssueStartButton = "banyan.sidebar.linear-start"
    static let addSessionSheet = "banyan.sheet.add-session"
    static let preferencesSheet = "banyan.sheet.preferences"

    static func sessionRow(_ id: String) -> String {
        "banyan.sidebar.session-row.\(id)"
    }

    static func sessionRowTitle(_ id: String) -> String {
        "banyan.sidebar.session-row.\(id).title"
    }

    static func sessionRowStatus(_ id: String) -> String {
        "banyan.sidebar.session-row.\(id).status"
    }
}
