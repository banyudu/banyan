import BanyanCore
import SwiftUI
import SwiftTerm

/// Keeps all live session terminal views alive and switches between them by
/// toggling `isHidden`. This avoids the SwiftUI view-tree diff and tmux
/// refresh that made session switches take ~1.3s, bringing them to ~16ms.
struct TerminalSwitcherView: NSViewRepresentable {
    let sessions: [BanyanSession]
    let selectedSessionID: String?
    let theme: TerminalTheme
    let fontFamily: String
    let fontSize: Double
    let focusRequestID: UUID
    var switchRequestedAt: DispatchTime?
    var selectionChangedAt: DispatchTime?

    func makeNSView(context: Context) -> TerminalSwitcherContainer {
        let container = TerminalSwitcherContainer()
        return container
    }

    func updateNSView(_ nsView: TerminalSwitcherContainer, context: Context) {
        nsView.update(
            switchRequestedAt: switchRequestedAt,
            selectionChangedAt: selectionChangedAt,
            sessions: sessions,
            selectedSessionID: selectedSessionID,
            theme: theme,
            fontFamily: fontFamily,
            fontSize: fontSize,
            focusRequestID: focusRequestID,
            onUserSubmittedInput: { session, buffer in
                session.noteUserSubmittedInput(buffer)
            },
            onTerminalReady: { session in
                PerformanceTelemetry.shared.noteSessionTerminalReady(sessionID: session.id)
                session.renderRestoredMessageIfNeeded(
                    theme: theme, fontFamily: fontFamily, fontSize: fontSize
                )
                guard session.status != .closed,
                      !session.isImportedHistory,
                      !session.needsManualAttach else {
                    return
                }
                session.start()
                session.refreshTerminalClient(immediately: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    session.refreshTerminalClient()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) {
                    session.recoverBlankTerminalClientIfNeeded()
                }
            }
        )
    }
}

final class TerminalSwitcherContainer: NSView {
    private var containers: [String: TerminalContainerView] = [:]
    private var initializedSessions: Set<String> = []
    private var activeSessionID: String?
    private var lastFocusRequestID: UUID?

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        switchRequestedAt: DispatchTime?,
        selectionChangedAt: DispatchTime?,
        sessions: [BanyanSession],
        selectedSessionID: String?,
        theme: TerminalTheme,
        fontFamily: String,
        fontSize: Double,
        focusRequestID: UUID,
        onUserSubmittedInput: @escaping (BanyanSession, String?) -> Void,
        onTerminalReady: @escaping (BanyanSession) -> Void
    ) {
        let liveSessions = sessions.filter { !$0.isImportedHistory && $0.status != .closed }
        let liveIDs = Set(liveSessions.map(\.id))

        // Remove containers for sessions that no longer exist
        for (id, container) in containers where !liveIDs.contains(id) {
            container.removeFromSuperview()
            containers.removeValue(forKey: id)
            initializedSessions.remove(id)
        }

        // Add containers for new sessions
        for session in liveSessions where containers[session.id] == nil {
            let container = TerminalContainerView(
                terminalView: session.terminalView,
                onUserSubmittedInput: { onUserSubmittedInput(session, $0) }
            )
            container.apply(theme: theme)
            session.apply(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
            container.translatesAutoresizingMaskIntoConstraints = false
            container.isHidden = true
            addSubview(container)
            NSLayoutConstraint.activate([
                container.leadingAnchor.constraint(equalTo: leadingAnchor),
                container.trailingAnchor.constraint(equalTo: trailingAnchor),
                container.topAnchor.constraint(equalTo: topAnchor),
                container.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            containers[session.id] = container
        }

        // Apply theme to all containers
        for session in liveSessions {
            guard let container = containers[session.id] else { continue }
            container.apply(theme: theme)
            container.onUserSubmittedInput = { onUserSubmittedInput(session, $0) }
            session.apply(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
        }

        // Switch visibility
        let selectionChanged = activeSessionID != selectedSessionID
        if selectionChanged {
            let isRevisit = selectedSessionID.map { initializedSessions.contains($0) } ?? false
            if let selAt = selectionChangedAt {
                PerformanceTelemetry.shared.recordDuration(
                    "switcher.from_selection",
                    durationMS: PerformanceTelemetry.elapsedMS(since: selAt),
                    sessionID: selectedSessionID,
                    detail: isRevisit ? "revisit" : "first"
                )
            }
            if let switchAt = switchRequestedAt {
                PerformanceTelemetry.shared.recordDuration(
                    "switcher.switch_visible",
                    durationMS: PerformanceTelemetry.elapsedMS(since: switchAt),
                    sessionID: selectedSessionID,
                    detail: isRevisit ? "revisit" : "first"
                )
            }
            if let oldID = activeSessionID, let oldContainer = containers[oldID] {
                oldContainer.isHidden = true
            }
            activeSessionID = selectedSessionID
        }

        if let newID = selectedSessionID, let newContainer = containers[newID] {
            if newContainer.isHidden {
                newContainer.isHidden = false
                newContainer.needsLayout = true
                newContainer.needsDisplay = true
                newContainer.terminalView.needsDisplay = true
            }

            // First-time initialization for this session
            if !initializedSessions.contains(newID),
               let session = liveSessions.first(where: { $0.id == newID }) {
                initializedSessions.insert(newID)
                newContainer.syncTerminalFrameIfNeeded(markNeedsDisplay: true)
                newContainer.performWhenTerminalReady(for: session.terminalView) {
                    onTerminalReady(session)
                }
            }

            // Focus on selection change or explicit focus request
            if selectionChanged || lastFocusRequestID != focusRequestID {
                lastFocusRequestID = focusRequestID
                newContainer.focusTerminalWhenReady()
            }
        }
    }
}
