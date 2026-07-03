import SwiftUI

struct PreferencesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SessionStore

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
                .buttonStyle(.borderless)
                .help("Close")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance")
                    .font(.headline)

                Picker("Terminal theme", selection: $store.terminalTheme) {
                    Label("System", systemImage: "circle.lefthalf.filled").tag(TerminalTheme.system)
                    Label("Light", systemImage: "sun.max").tag(TerminalTheme.light)
                    Label("Dark", systemImage: "moon").tag(TerminalTheme.dark)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 420, height: 180)
    }
}
