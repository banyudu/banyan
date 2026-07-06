import AppKit
import BanyanCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: SessionStore
    @State private var showingPreferences = false

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
                        onOpenLinear: store.openSelectedLinearIssue,
                        onOpenPullRequest: store.openSelectedPullRequest
                    )
                }
            }
            ToolbarItemGroup(placement: .primaryAction) {
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
        .background(WindowTitleConfigurator())
        .preferredColorScheme(store.terminalTheme.colorScheme)
        .accessibilityIdentifier(AccessibilityID.root)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedSessionID) {
                ForEach(store.sidebarGroups) { group in
                    Section {
                        ForEach(group.items) { item in
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
                                onRemove: {
                                    try? store.remove(id: item.session.id)
                                }
                            )
                            .tag(item.session.id)
                            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                        }
                    } header: {
                        Text(group.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .listStyle(.sidebar)
            .accessibilityIdentifier(AccessibilityID.sidebarList)

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

                if let selected = store.selectedSession {
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
        .accessibilityIdentifier(AccessibilityID.sidebar)
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

    @ViewBuilder
    private var detail: some View {
        if let session = store.selectedSession {
            if session.isImportedHistory {
                ImportedSessionHistoryView(session: session)
                    .accessibilityIdentifier(AccessibilityID.detail)
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
                .accessibilityIdentifier(AccessibilityID.detail)
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
}

private extension SessionContextInfo {
    var hasTitlebarContent: Bool {
        let hasLinearTitle = linearIssueID?.isEmpty == false
            && linearIssueTitle?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        let hasPullRequest = pullRequestURL?.isEmpty == false
        return hasLinearTitle || hasPullRequest
    }
}

private struct TitleBarContextView: View {
    let context: SessionContextInfo
    let onOpenLinear: () -> Void
    let onOpenPullRequest: () -> Void

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

            if let pullRequestURL = context.pullRequestURL, !pullRequestURL.isEmpty {
                Spacer(minLength: 4)
                TitleBarIconButton(
                    accessibilityIdentifier: AccessibilityID.toolbarPullRequestLink,
                    systemImage: "arrow.triangle.pull",
                    help: pullRequestHelp,
                    action: onOpenPullRequest
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

    private var pullRequestHelp: String {
        if let number = context.pullRequestNumber {
            return "Open GitHub pull request #\(number) (Cmd-G)"
        }
        if let title = context.pullRequestTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return "Open GitHub pull request: \(title)"
        }
        return "Open GitHub pull request (Cmd-G)"
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

private struct TitleBarIconButton: View {
    let accessibilityIdentifier: String
    let systemImage: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isHovered ? .primary : .secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover(perform: setHovered)
        .onDisappear(perform: resetHover)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private func setHovered(_ hovered: Bool) {
        guard isHovered != hovered else { return }
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
    private var timer: Timer?

    deinit {
        timer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { return }
        configureTitlebar()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.configureTitlebar()
        }
    }

    private func configureTitlebar() {
        DispatchQueue.main.async { [weak self] in
            WindowTitleConfigurator.configure(window: self?.window)
        }
    }
}

private struct SessionRow: View {
    @ObservedObject var session: BanyanSession
    let depth: Int
    let titleOverride: String?
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
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

            if !session.isImportedHistory {
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
            Button("Close") {
                onClose()
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
        if titleOverride == nil,
           let titleURL = session.titleURL,
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
                .foregroundStyle(session.isImportedHistory ? .secondary : .primary)
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
