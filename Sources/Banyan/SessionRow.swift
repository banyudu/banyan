import AppKit
import BanyanCore
import Combine
import SwiftUI
import UniformTypeIdentifiers


enum SessionRowHoverRegion: Equatable {
    case row
    case costGutter

    /// Space reserved after the row's trailing controls. Keeping this gutter in
    /// the layout, rather than treating the last few points of a control as a
    /// hover target, prevents the cost affordance from stealing close/handoff
    /// clicks or making either button disappear as the pointer approaches it.
    static let costGutterWidth: CGFloat = 10

    static func region(
        at location: CGPoint?,
        rowWidth: CGFloat,
        hasSessionCost: Bool
    ) -> SessionRowHoverRegion? {
        guard let location else { return nil }
        guard hasSessionCost else { return .row }
        guard rowWidth > 0 else { return nil }
        return location.x >= rowWidth - costGutterWidth ? .costGutter : .row
    }
}

struct SessionCostAccess {
    let source: () -> SessionCostTranscriptSource?
    let estimate: (SessionCostTranscriptSource) async -> SessionCostEstimate?
}

/// Latest pointer geometry for a row. This is a plain reference box, not
/// observable state: `onContinuousHover` fires for every mouse move, and
/// storing the location in `@State` would rebuild the whole row body on each
/// one. Only the derived `SessionRowHoverRegion` is `@State`.
final class SessionRowHoverTracker {
    var location: CGPoint?
    var rowWidth: CGFloat = 0
}

struct SessionRow: View, Equatable {
    @ObservedObject var session: BanyanSession
    let selection: SessionSelection
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
    let isFolded: Bool
    let jumpKeyLabel: String
    var jumpShortcuts: SessionJumpShortcuts? = nil
    @ObservedObject var workState: SessionWorkState
    private var workSummary: SessionWorkSummary? { workState.summary }
    let actionOwner: ObjectIdentifier
    let openWorkSession: (String) -> Void
    let onSelect: () -> Void
    let onToggleFold: () -> Void
    let onClose: () -> Void
    let onRestart: () -> Void
    let onRespawn: () -> Void
    let onRecover: () -> Void
    let isHandoffAvailable: Bool
    let isHandoffPending: Bool
    let onHandoff: () -> Void
    let onCodexRemoteHandoff: () -> Void
    let onRemove: () -> Void
    let onChooseParent: () -> Void
    var moveOptions: SessionSidebarMoveOptions = []
    var onMove: (SessionSidebarMoveCommand) -> Void = { _ in }
    let onToggleSuspended: () -> Void
    let onSetFrozen: (Bool) -> Void
    let onSetDeepSuspended: (Bool) -> Void
    let onFocusTerminal: () -> Void
    let onReopenHistory: () -> Void
    var sessionCost: SessionCostAccess? = nil

    // Actions target the same store and session for this row's lifetime; their
    // captures are recreated by ContentView on unrelated store notifications.
    // Compare their owner and all captured presentation inputs instead. Session
    // updates and this row's selection subscription still redraw it directly.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.session === rhs.session && lhs.selection === rhs.selection
            && lhs.actionOwner == rhs.actionOwner
            && lhs.launchProfile == rhs.launchProfile && lhs.depth == rhs.depth
            && lhs.titleOverride == rhs.titleOverride && lhs.isHistory == rhs.isHistory
            && lhs.isParent == rhs.isParent && lhs.showsDisclosureGutter == rhs.showsDisclosureGutter
            && lhs.isFolded == rhs.isFolded
            && lhs.jumpKeyLabel == rhs.jumpKeyLabel && lhs.workState === rhs.workState
            && lhs.jumpShortcuts === rhs.jumpShortcuts
            && lhs.isHandoffAvailable == rhs.isHandoffAvailable && lhs.isHandoffPending == rhs.isHandoffPending
            && (lhs.sessionCost != nil) == (rhs.sessionCost != nil)
            && lhs.moveOptions == rhs.moveOptions
    }

    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var isIssueLinkHovered = false
    @State private var workStatusBounds: CGRect = .null
    @State private var isHandoffHovered = false
    @State private var hoverRegion: SessionRowHoverRegion?
    @State private var hoverTracker = SessionRowHoverTracker()
    @State private var isPointerCursorPushed = false
    @State private var selectedInRow: Bool?
    @State private var residentCostTier: SessionCostTier = .standard
    @FocusState private var isRenameFocused: Bool

    private var isSelected: Bool {
        selectedInRow ?? (selection.selectedSessionID == session.id)
    }

    private var isRowHovered: Bool {
        hoverRegion != nil
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
    /// trailing edge.
    private var showsHandoffButton: Bool {
        isHandoffAvailable && session.canDispatchHandoff && !isHandoffPending
    }

    var body: some View {
        let _ = EnergyTrace.count("session.row.body", sessionID: session.id)
        let costTier = residentCostTier
        HStack(spacing: 4) {
            // All rows in a group with any nesting share a fixed leading
            // slot, so same-depth badges align whether or not a given row
            // has a disclosure triangle of its own.
            if showsDisclosureGutter {
                if isParent {
                    Button(action: onToggleFold) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14, height: 18)
                            .rotationEffect(.degrees(isFolded ? 0 : 90))
                    }
                    .buttonStyle(.banyanPlainLabelOnly)
                    .help(isFolded ? "Unfold child sessions" : "Fold child sessions")
                    .accessibilityLabel(isFolded ? "Unfold child sessions" : "Fold child sessions")
                    .accessibilityIdentifier(AccessibilityID.sessionRowDisclosure(session.id))
                } else {
                    Color.clear
                        .frame(width: 14, height: 18)
                }
            }

            if let jumpShortcuts {
                SessionShortcutMapObserver(shortcuts: jumpShortcuts) {
                    JumpKeyBadge(
                        label: jumpShortcuts.label(for: session.id),
                        provider: brandingProvider,
                        costTier: costTier
                    )
                }
            } else {
                JumpKeyBadge(
                    label: jumpKeyLabel,
                    provider: brandingProvider,
                    costTier: costTier
                )
            }

            // A plain-shell profile (the built-in `zsh`) matches every session
            // whose command is empty, including one that later became an agent
            // session. Only let a profile brand the row when it declares an
            // icon identity; otherwise the detected provider wins, so an agent
            // started by hand inside a shell is still recognized.
            if isBrandedByLaunchProfile, let launchProfile {
                NewSessionLaunchIcon(launch: launchProfile, size: 15)
                    .accessibilityLabel(launchProfile.label)
            } else if let provider = session.displayAgentProvider {
                AgentProviderIcon(provider: provider, size: 15, helpText: session.agentRuntimeIdentityLabel)
                    .accessibilityLabel(provider.displayName)
            } else if !session.isImportedHistory {
                ShellSessionIcon()
            }

            if let position = session.agentQueuePosition {
                Text("Queued #\(position)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("session.\(session.id).queued")
            }

            if session.isFrozen {
                Image(systemName: "snowflake")
                    .foregroundStyle(.secondary)
                    .help("Frozen — interact to resume")
                    .accessibilityLabel("Agent frozen — interact to resume")
                    .accessibilityIdentifier("session.\(session.id).frozen")
            }

            if session.isDeepSuspended {
                Image(systemName: session.isDeepResuming ? "arrow.clockwise" : "powersleep")
                    .help((session as? TerminalSession)?.deepRecoveryIsUncertain == true ? "Recovery journal unavailable — input blocked; retry Resume" : session.isDeepTerminating ? "Waiting for graceful exit — recovery retained" : session.isDeepResuming ? "Resuming agent…" : "Agent suspended — RAM released; focus to resume")
                    .accessibilityLabel(session.isDeepResuming ? "Agent resuming" : "Agent deeply suspended")
                    .accessibilityIdentifier("session.\(session.id).deepSuspended")
            }

            if session.isSuspended && !session.isImportedHistory && session.status != .closed {
                Image(systemName: "pause.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 18)
                    .help("Parked — Banyan is not supervising or rendering this session. Its \(session.backingSessionName) and agent are still running.")
                    .accessibilityLabel("Parked")
                    .accessibilityIdentifier(AccessibilityID.sessionRowSuspendedBadge(session.id))
            }

            if !session.isImportedHistory && session.status != .closed && !hidesStatusIcon && session.agentQueuePosition == nil {
                Image(systemName: session.status.systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(session.status.sidebarTint)
                    .frame(width: 14, height: 16)
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

            if let summary = workSummary, summary.own.managed || summary.own.background || !summary.descendants.isEmpty {
                SessionWorkStatusButton(summary: summary, openSession: openWorkSession)
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .named("session-work-row-\(session.id)"))
                    } action: { workStatusBounds = $0 }
                    .onDisappear { workStatusBounds = .null }
            } else if session.workflowRecoveryError != nil {
                Text("Workflow unavailable").font(.caption2).foregroundStyle(.red)
            }
            if let error = session.coordinationRecoveryError {
                Text("Coordination unavailable").font(.caption2).foregroundStyle(.red)
                    .help(error)
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

            if sessionCost != nil {
                Color.clear
                    .frame(width: SessionRowHoverRegion.costGutterWidth, height: 1)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
        .padding(.vertical, 2)
        .padding(.leading, CGFloat(depth) * 18)
        .padding(.leading, 4)
        .background(rowBackground)
        .opacity(dimsRow ? 0.55 : 1)
        .contentShape(Rectangle())
        .coordinateSpace(name: "session-work-row-\(session.id)")
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            hoverTracker.rowWidth = width
            updateHoverRegion()
        }
        .onContinuousHover { phase in
            switch phase {
            case let .active(location):
                hoverTracker.location = location
                updateHoverRegion()
            case .ended:
                hoverTracker.location = nil
                setHoverRegion(nil)
            }
        }
        .overlay(alignment: .trailing) {
            if let sessionCost {
                SessionCostGutter(
                    session: session,
                    isHovered: isRowHovered,
                    source: sessionCost.source,
                    estimate: sessionCost.estimate,
                    onEstimate: { estimate in
                        residentCostTier = SessionCostTier(estimate: estimate)
                    }
                )
            }
        }
        .task(id: residentCostTierRefreshKey) {
            await refreshResidentCostTier()
        }
        .onChange(of: isRenaming) { _, _ in syncPointerCursor() }
        // Observing the shared object redraws every row on every selection and
        // rename request. Only the old/new selections need a new highlight.
        .onReceive(selection.$selectedSessionID.map { $0 == session.id }.removeDuplicates()) { selected in
            if selectedInRow != selected { selectedInRow = selected }
        }
        .onReceive(selection.$renameRequestID.dropFirst()) { _ in
            if selection.selectedSessionID == session.id {
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
                Divider()
                Button("Move Up") { onMove(.up) }
                    .disabled(!moveOptions.contains(.up))
                Button("Move Down") { onMove(.down) }
                    .disabled(!moveOptions.contains(.down))
                Button("Indent Under Previous Sibling") { onMove(.indent) }
                    .disabled(!moveOptions.contains(.indent))
                Button("Move Out One Level") { onMove(.outdent) }
                    .disabled(!moveOptions.contains(.outdent))
                Button("Move to Top Level") { onMove(.topLevel) }
                    .disabled(!moveOptions.contains(.topLevel))
                // SwiftUI builds context-menu content during ordinary row updates.
                // Resolve the project hierarchy only when the user opens the picker.
                Button("Move to…", action: onChooseParent)
                Divider()
                if session is TerminalSession {
                    if session.agentProvider == .codex {
                        Button("Continue in ChatGPT Remote…", action: onCodexRemoteHandoff)
                    }
                    Button(session.isDeepSuspended ? "Resume Agent" : "Deep Suspend Agent") {
                        onSetDeepSuspended(!session.isDeepSuspended)
                    }
                    .disabled(session.isDeepResuming || (!session.isDeepSuspended && (isSelected || session.isSuspended || ![.idle, .needInput].contains(session.status))))
                    Button(session.isFrozen ? "Unfreeze Agent" : "Freeze Agent") {
                        onSetFrozen(!session.isFrozen)
                    }
                    .disabled(!session.isFrozen && (isSelected || session.isSuspended || ![.idle, .needInput].contains(session.status)))
                    if !session.isFrozen {
                        Button("Resume Stopped Agent") { onSetFrozen(false) }
                    }
                }
                Button(session.isSuspended ? "Resume Parked Session" : "Park Session") {
                    onToggleSuspended()
                }
                if session.canRestart {
                    Button("Restart") {
                        onRestart()
                    }
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
        .alert("Agent freeze", isPresented: Binding(
            get: { (session as? TerminalSession)?.freezeError != nil },
            set: { if !$0 { (session as? TerminalSession)?.freezeError = nil } }
        )) {
            Button("OK") { (session as? TerminalSession)?.freezeError = nil }
        } message: {
            Text((session as? TerminalSession)?.freezeError ?? "")
        }
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

    private var residentCostTierRefreshKey: String {
        [
            session.agentProvider?.rawValue ?? "",
            session.agentSessionID ?? "",
            session.historyTranscriptURL?.path ?? "",
            session.status.rawValue
        ].joined(separator: "|")
    }

    private func refreshResidentCostTier() async {
        guard let sessionCost else {
            residentCostTier = .standard
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        guard !Task.isCancelled else { return }
        guard let source = sessionCost.source() else {
            residentCostTier = .standard
            return
        }
        let estimate = await sessionCost.estimate(source)
        guard !Task.isCancelled else { return }
        residentCostTier = SessionCostTier(estimate: estimate)
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

    private func updateHoverRegion() {
        setHoverRegion(SessionRowHoverRegion.region(
            at: hoverTracker.location,
            rowWidth: hoverTracker.rowWidth,
            hasSessionCost: sessionCost != nil
        ))
    }

    private func setHoverRegion(_ region: SessionRowHoverRegion?) {
        guard hoverRegion != region else { return }
        hoverRegion = region
        syncPointerCursor()
    }

    private func resetRowHover() {
        hoverTracker.location = nil
        setHoverRegion(nil)
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

    /// The unemphasized selection gray sat only ~3 levels above the dark
    /// sidebar, so the active session was hard to find. An accent tint stands
    /// out in both appearances and cannot be mistaken for the neutral hover fill.
    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.28))
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
    private var hidesStatusIcon: Bool {
        session.displayAgentProvider == nil && session.status == .running
    }

    private func isOverChildSessionSummary(at location: CGPoint) -> Bool {
        workSummary?.descendants.isEmpty == false && workStatusBounds.contains(location)
    }

    private var doubleClickRenameGesture: some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .named("session-work-row-\(session.id)")).onEnded { event in
            guard !isOverChildSessionSummary(at: event.location) else { return }
            if isHistory {
                onReopenHistory()
            } else {
                beginRename()
            }
        }
    }

    private var singleClickSelectGesture: some Gesture {
        SpatialTapGesture(count: 1, coordinateSpace: .named("session-work-row-\(session.id)")).onEnded { event in
            // Parent summaries must not bubble into the row's simultaneous
            // selection gesture. Keyboard/AX button activation has no row tap.
            if !isRenaming && !isOverChildSessionSummary(at: event.location) {
                onSelect()
            }
        }
    }
}

extension SessionStatus {
    var sidebarTint: Color {
        switch self {
        case .running, .executing, .longRunningShell, .review: .blue
        case .subagents: .purple
        case .needInput, .asking: .orange
        case .completed: .green
        case .failed: .red
        case .idle, .closed: .secondary
        }
    }
}

private struct ShellSessionIcon: View {
    var body: some View {
        Image(systemName: "terminal")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 15, height: 15)
            .help("Shell")
            .accessibilityLabel("Shell")
    }
}
