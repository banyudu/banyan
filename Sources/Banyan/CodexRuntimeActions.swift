import SwiftUI

/// Separate from the conversation view so rollout/fallback controls compose
/// with the native transcript and approval UI.
struct CodexRuntimeActions: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: CodexSession

    var body: some View {
        HStack {
            Text(store.enableNativeCodex ? "Native Codex (preview)" : "Native Codex disabled in Preferences")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Use Codex CLI") {
                Task {
                    do { try await store.fallbackCodexSessionToCLI(id: session.id) }
                    catch { store.codexSessionError = error.localizedDescription }
                }
            }
            .disabled(session.state.runtime.type == "active" || session.state.activeTurnID != nil || session.state.needsAttention)
            .help("Continue the same thread in an interactive CLI session")
        }
        .padding(8)
        Divider()
    }
}
