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
                .buttonStyle(.borderless)
                .help("Close")
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance")
                    .font(.headline)

                Picker("Terminal theme", selection: $store.terminalTheme) {
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

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 440, height: 260)
        .accessibilityIdentifier(AccessibilityID.preferencesSheet)
    }
}
