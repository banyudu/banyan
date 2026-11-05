import AppKit
import BanyanCore
import Combine
import SwiftUI
import UniformTypeIdentifiers


/// Session changes do not invalidate the store. Observe the session at the
/// conditional boundary so dismissing an error also removes its overlay.
struct SessionDetailOverlay: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: BanyanSession

    var body: some View {
        if session.status == .closed {
            ClosedSessionHistoryView(session: session)
        } else if session.isImportedHistory {
            ImportedSessionHistoryView(session: session)
        } else if session.isDeepSuspended || (session as? TerminalSession)?.deepSuspendError != nil {
            VStack {
                Text((session as? TerminalSession)?.deepRecoveryIsUncertain == true ? "Recovery state unavailable — input blocked" : session.isDeepTerminating ? "Waiting for agent to exit…" : session.isDeepResuming ? "Resuming agent…" : session.isDeepSuspended ? "Agent suspended — memory released" : "Deep suspend unavailable")
                if let error = (session as? TerminalSession)?.deepSuspendError {
                    Text(error).font(.caption)
                }
                if session.isDeepSuspended {
                    Button("Resume Agent") { try? store.deepResumeAgent(id: session.id) }
                        .disabled(session.isDeepResuming)
                } else {
                    Button("Dismiss") { (session as? TerminalSession)?.deepSuspendError = nil }
                }
            }
            .padding()
            .background(.regularMaterial)
        } else if session.isFrozen {
            VStack {
                Text("Frozen — interact to resume")
                Button("Unfreeze Agent") {
                    try? store.unfreezeAgent(id: session.id)
                }
            }
            .padding()
            .background(.regularMaterial)
        } else if session.isSuspended {
            VStack(spacing: 0) {
                SuspendedSessionBanner(session: session)
                Divider()
                Spacer()
            }
            .background(.background)
        } else if let native = session as? CodexSession {
            CodexSessionDetail(session: native, nativeModeEnabled: store.enableNativeCodex, onOpenCLIFallback: {
                Task {
                    do { try await store.fallbackCodexSessionToCLI(id: native.id) }
                    catch { store.codexSessionError = error.localizedDescription }
                }
            })
                .id(native.id)
                .background(.background)
        } else if let puck = session as? PuckSession {
            PuckSessionDetail(session: puck)
                .id(puck.id)
                .background(.background)
        } else if session.codexRetryStatus != nil {
            VStack(spacing: 0) {
                CodexRetryBanner(session: session)
                Spacer().allowsHitTesting(false)
            }
        } else if session.needsManualAttach {
            VStack(spacing: 0) {
                TerminalReconnectBanner(session: session)
                Divider()
                Spacer()
            }
            .background(.background)
        }
    }
}

/// Keeps fast selection invalidation scoped to the terminal representable instead
/// of rebuilding the entire navigation split rooted at `ContentView`.
struct SelectionAwareTerminalSwitcher: View {
    @ObservedObject var selection: SessionSelection
    let sessions: [TerminalSession]
    let theme: TerminalTheme
    let fontFamily: String
    let fontSize: Double
    let focusRequestID: UUID
    let switchRequestedAt: DispatchTime?
    let onTerminalSlashCommand: (TerminalSession, TerminalSlashCommand) -> Void

    var body: some View {
        TerminalSwitcherView(
            sessions: sessions,
            selectedSessionID: selection.selectedSessionID,
            theme: theme,
            fontFamily: fontFamily,
            fontSize: fontSize,
            focusRequestID: focusRequestID,
            switchRequestedAt: switchRequestedAt,
            selectionChangedAt: selection.changedAt,
            clickAt: selection.pendingClickAt,
            selection: selection,
            onTerminalSlashCommand: onTerminalSlashCommand
        )
    }
}
