import AppKit
import BanyanCore
import Combine
import SwiftUI
import UniformTypeIdentifiers


struct ClosedSessionHistoryView: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: BanyanSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let provider = session.agentProvider {
                    AgentProviderIcon(provider: provider, showsPeakBadge: false)
                } else {
                    Image(systemName: "terminal")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(PathDisplayName.make(path: session.cwd, homeDirectory: store.host.homeDirectory.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                // Trimming rewrites a local agent transcript; a daemon-owned
                // session has none to rewrite.
                if session.matchesAgentTranscripts {
                    Button {
                        reopenTrimmed()
                    } label: {
                        Image(systemName: "scissors")
                    }
                    .buttonStyle(.banyanBorderless)
                    .controlSize(.small)
                    .help("Reopen with stale tool output trimmed to save context (experimental)")
                }

                if store.isRecoveringHistoryResume(id: session.id) {
                    ProgressView()
                        .controlSize(.small)
                        .help("Finding the agent session for this working directory")
                } else {
                    Button {
                        reopenSession()
                    } label: {
                        Label("Reopen", systemImage: "arrow.uturn.forward.circle.fill")
                    }
                    .buttonStyle(.banyanBorderedProminent)
                    .controlSize(.small)
                    .help("Resume the closed Banyan session")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Group {
                if let error = store.historyResumeError(id: session.id) {
                    VStack(spacing: 16) {
                        ContentUnavailableView(
                            "Resume Unavailable",
                            systemImage: "exclamationmark.triangle",
                            description: Text(error)
                        )
                        Button {
                            openShell()
                        } label: {
                            Label("Open zsh in Working Directory", systemImage: "terminal")
                        }
                        .buttonStyle(.banyanBorderedProminent)
                    }
                } else {
                    ContentUnavailableView(
                        "Closed Session",
                        systemImage: "archivebox",
                        description: Text("This history item was closed in Banyan. Reopen it to resume the agent session.")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func reopenSession() {
        _ = try? store.respawn(id: session.id)
    }

    private func reopenTrimmed() {
        store.respawnTrimmed(id: session.id)
    }

    private func openShell() {
        _ = try? store.openShellForClosedSession(id: session.id)
    }
}

struct ImportedSessionHistoryView: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: BanyanSession
    @State private var preview = "Loading..."
    @State private var resumePrompt = ""
    @FocusState private var isResumePromptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let provider = session.agentProvider {
                    AgentProviderIcon(provider: provider, showsPeakBadge: false)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                    Text(PathDisplayName.make(path: session.cwd, homeDirectory: store.host.homeDirectory.path))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button {
                    resumeTrimmed()
                } label: {
                    Image(systemName: "scissors")
                }
                .buttonStyle(.banyanBorderless)
                .controlSize(.small)
                .help("Resume with stale tool output trimmed to save context (experimental)")

                Button {
                    resumeSession()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.banyanBorderedProminent)
                .controlSize(.small)
                .help("Resume in a Banyan session")

                Button {
                    openTranscript()
                } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .buttonStyle(.banyanBorderless)
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
            .scrollIndicators(.hidden)
            .hidesVerticalScroller()

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
                .buttonStyle(.banyanBorderless)
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
        let loadedPreview = await store.transcriptPreview(from: url, provider: provider)
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

    private func resumeTrimmed() {
        store.resumeImportedHistoryTrimmed(id: session.id)
    }

    private func resumeWithPrompt() {
        let prompt = resumePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        resumePrompt = ""
        _ = try? store.resumeImportedHistory(id: session.id, prompt: prompt)
    }
}

struct TerminalReconnectBanner: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: BanyanSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle")
                    .foregroundStyle(Color(nsColor: session.tone.nsColor))
                Text(statusText)
                    .font(.callout)
                Spacer()
                if store.isRecoveringWorktree(id: session.id) {
                    ProgressView()
                        .controlSize(.small)
                        .help("Recreating this session's worktree")
                } else {
                    Button {
                        if session.needsRecovery {
                            try? store.recover(id: session.id)
                        } else {
                            try? store.respawn(id: session.id)
                        }
                    } label: {
                        Label(session.needsRecovery ? "Recover" : "Attach", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.banyanBorderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier(AccessibilityID.terminalAttachButton)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            // Attach cannot succeed while the folder is missing, so say why
            // rather than leaving a button that only ever re-fails.
            if let failure = store.worktreeRecoveryError(id: session.id) {
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .accessibilityIdentifier(AccessibilityID.terminalRecoveryFailureMessage)
            }
        }
        .background(.bar)
        .accessibilityIdentifier(AccessibilityID.terminalReconnectBanner)
    }

    private var statusText: String {
        if store.isRecoveringWorktree(id: session.id) {
            return "Recreating this session's worktree…"
        }
        if session.needsRecovery {
            return "Session needs recovery after restart"
        }
        return "Session is detached"
    }
}

/// Shown over the frozen pane of a parked session. Nothing was torn down, so the
/// only thing on offer is putting it back in the working set.
struct SuspendedSessionBanner: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: BanyanSession

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Session is parked")
                    .font(.callout)
                Text("Banyan stopped supervising and rendering it. Its \(session.backingSessionName) and any agent inside are still running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button {
                try? store.resume(id: session.id)
            } label: {
                Label("Resume", systemImage: "play")
            }
            .buttonStyle(.banyanBorderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.terminalResumeButton)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier(AccessibilityID.terminalSuspendedBanner)
    }
}
