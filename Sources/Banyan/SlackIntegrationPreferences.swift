import BanyanCore
import SwiftUI

/// Preferences configure one private control channel. Tokens are never loaded
/// back into text fields or written to the policy file.
struct SlackIntegrationPreferences: View {
    @ObservedObject var controller: SlackIntegrationController
    @State private var botToken = ""
    @State private var appToken = ""
    @State private var workspace = ""
    @State private var channel = ""
    @State private var user = ""
    @State private var message: String?

    private var editingDisabled: Bool {
        if controller.enabled { return true }
        switch controller.connection {
        case .starting, .connecting, .connected, .offline, .stopping: return true
        case .disabled, .stopped, .failed: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Slack integration").font(.headline)
            Text("Status: \(controller.connection.label)").font(.caption)
            SecureField("Bot token", text: $botToken)
                .accessibilityIdentifier("banyan.preferences.slack-bot-token")
            SecureField("Socket Mode app token", text: $appToken)
                .accessibilityIdentifier("banyan.preferences.slack-app-token")
            Button("Save tokens in Keychain") {
                Task {
                    do {
                        try await controller.saveCredentials(botToken: botToken, appToken: appToken)
                        botToken = ""; appToken = ""; message = "Tokens saved in Keychain."
                    } catch { message = error.localizedDescription }
                }
            }
            .disabled(botToken.isEmpty || appToken.isEmpty || editingDisabled)
            TextField("Workspace ID", text: $workspace).disabled(editingDisabled)
            TextField("Private channel ID", text: $channel).disabled(editingDisabled)
            TextField("Allowed user ID", text: $user).disabled(editingDisabled)
            HStack {
                Button("Add allowed user") {
                    do {
                        try controller.setAllowlist(controller.allowed + [.init(workspace: workspace, channel: channel, user: user)])
                        user = ""; message = nil
                    } catch { message = error.localizedDescription }
                }
                .disabled(editingDisabled || workspace.isEmpty || channel.isEmpty || user.isEmpty)
                if !controller.allowed.isEmpty {
                    Button("Clear allowlist") {
                        do { try controller.setAllowlist([]); message = nil }
                        catch { message = error.localizedDescription }
                    }.disabled(editingDisabled)
                }
            }
            ForEach(controller.allowed.indices, id: \.self) { index in
                let entry = controller.allowed[index]
                Text("\(entry.workspace) / \(entry.channel) / \(entry.user)")
                    .font(.caption).textSelection(.enabled)
            }
            TextField("Slack Python interpreter", text: $controller.pythonPath).disabled(editingDisabled)
            HStack {
                Button("Enable and connect") {
                    Task { do { try await controller.start(); message = nil } catch { message = error.localizedDescription } }
                }.disabled(editingDisabled || controller.allowed.isEmpty)
                Button("Reconnect") {
                    do { try controller.reconnect(); message = nil } catch { message = error.localizedDescription }
                }.disabled(!controller.enabled || controller.connection == .stopping || controller.connection == .starting)
                Button("Disable") {
                    do { try controller.stop(); message = nil } catch { message = error.localizedDescription }
                }.disabled(!controller.enabled && controller.connection != .starting)
            }
            Text("Use one private channel; everyone in it can see posted context. Keep this Mac, Banyan and the connector running and awake. Install the pinned Slack Python environment before connecting.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear {
            if let first = controller.allowed.first { workspace = first.workspace; channel = first.channel }
        }
    }
}
