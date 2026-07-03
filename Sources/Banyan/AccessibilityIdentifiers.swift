enum AccessibilityID {
    static let root = "banyan.root"
    static let sidebar = "banyan.sidebar"
    static let sidebarList = "banyan.sidebar.list"
    static let sidebarFooter = "banyan.sidebar.footer"
    static let detail = "banyan.detail"
    static let emptyDetail = "banyan.detail.empty"
    static let terminal = "banyan.terminal"
    static let terminalHeader = "banyan.terminal.header"
    static let terminalHeaderTitle = "banyan.terminal.header.title"
    static let terminalHeaderDirectory = "banyan.terminal.header.directory"
    static let terminalHeaderCommand = "banyan.terminal.header.command"
    static let terminalAttachButton = "banyan.terminal.header.attach"
    static let toolbarAddSession = "banyan.toolbar.add-session"
    static let toolbarPreferences = "banyan.toolbar.preferences"
    static let sidebarAddSession = "banyan.sidebar.add-session"
    static let sidebarOptions = "banyan.sidebar.options"
    static let sidebarEditSelected = "banyan.sidebar.edit-selected"
    static let sidebarCloseSelected = "banyan.sidebar.close-selected"
    static let addSessionSheet = "banyan.sheet.add-session"
    static let editSessionSheet = "banyan.sheet.edit-session"
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
