import BanyanCore
import SwiftUI

/// Optional, user-opened guidance for continuing a CLI conversation remotely.
struct CodexTUIHandoffView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: SessionStore
    @ObservedObject var session: TerminalSession
    @State private var busy = false
    @State private var errorMessage: String?

    private var observation: CodexTUIOwnershipObservation? {
        guard let value = store.codexTUIOwnership[session.id], value.threadID == session.agentSessionID else { return nil }
        return value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue in ChatGPT Remote").font(.headline)
            Text("\(session.displayTitle) · \(session.cwd)")
                .font(.caption).foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("This is optional. You can keep using Codex normally in this terminal without preparing a handoff.")
                .font(.callout)
            if let observation {
                Text(observation.state.title).font(.subheadline)
                Text("Checked \(observation.observedAt.formatted(date: .abbreviated, time: .standard)). Check again after terminal activity.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(observation?.state.message
                ?? "To move this conversation to ChatGPT Remote, finish the current turn and answer pending requests. Prepare the handoff, enter /quit in Codex, then check that the CLI has exited before reopening the same conversation remotely.")
                .font(.callout)
                .textSelection(.enabled)
            if session.agentSessionID?.isEmpty != false {
                Text("The conversation ID is not available yet. Complete a turn in Codex before preparing a handoff.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if session.isSuspended || session.isFrozen || session.isDeepSuspended {
                Text("Resume the Codex terminal before preparing a handoff.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Prepare Remote Handoff") { perform(check: false) }
                Button("Check CLI Exit") { perform(check: true) }
            }
            .disabled(busy || session.agentSessionID?.isEmpty != false
                || session.isSuspended || session.isFrozen || session.isDeepSuspended)
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if let id = session.agentSessionID {
                Text("Thread: \(id)").font(.caption).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 540, alignment: .leading)
    }

    private func perform(check: Bool) {
        busy = true
        errorMessage = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await store.codexTUIHandoff(id: session.id, checkOnly: check) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
