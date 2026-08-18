import SwiftUI

struct PreferencesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SessionStore
    private let fontFamilies = ["Menlo", "SF Mono", "Monaco", "Andale Mono", "Courier New"]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Preferences")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.banyanBorderless)
                .help("Close")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance")
                    .font(.headline)

                Picker("Theme", selection: $store.terminalTheme) {
                    ForEach(TerminalTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                .pickerStyle(.menu)

                Picker("Font", selection: $store.terminalFontFamily) {
                    ForEach(fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }

                HStack {
                    Text("Size")
                    Slider(value: $store.terminalFontSize, in: 10...22, step: 1)
                    Text("\(Int(store.terminalFontSize))")
                        .monospacedDigit()
                        .frame(width: 28, alignment: .trailing)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Codex")
                    .font(.headline)

                Toggle("Enable Codex app-server mode", isOn: $store.enableCodexAppServerMode)

                Text(codexConnectionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let diagnostic = store.sessionLaunchConfigurationDiagnostic {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Session launch profiles")
                        .font(.headline)
                    Text(diagnostic)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 440, height: 400)
        .accessibilityIdentifier(AccessibilityID.preferencesSheet)
    }

    private var codexConnectionDescription: String {
        if store.enableCodexAppServerMode {
            return "For new Codex sessions, Banyan starts the local remote-control daemon and connects the interactive TUI to it. Existing sessions keep their current connection."
        }
        return "Direct mode gives Banyan's interactive TUI exclusive ownership of its Codex threads. Enable app-server mode before creating a session you want to continue from ChatGPT Remote."
    }
}
