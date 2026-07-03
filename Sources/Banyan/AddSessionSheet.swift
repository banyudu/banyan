import SwiftUI

struct AddSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SessionStore

    @State private var id = ""
    @State private var title = ""
    @State private var cwd = FileManager.default.currentDirectoryPath
    @State private var command = ""
    @State private var tone: SessionTone = .blue

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Session")
                .font(.title2.weight(.semibold))

            Form {
                TextField("ID", text: $id)
                TextField("Title", text: $title)
                HStack {
                    TextField("Working Directory", text: $cwd)
                    Button {
                        chooseDirectory()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Choose working directory")
                }
                TextField("Command", text: $command)
                Picker("Tone", selection: $tone) {
                    ForEach(SessionTone.allCases) { tone in
                        Text(tone.label).tag(tone)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Spawn") {
                    store.spawn(
                        id: id.isEmpty ? nil : id,
                        title: title.isEmpty ? nil : title,
                        cwd: cwd,
                        command: command,
                        tone: tone
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
        .accessibilityIdentifier(AccessibilityID.addSessionSheet)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: NSString(string: cwd).expandingTildeInPath)
        if panel.runModal() == .OK, let url = panel.url {
            cwd = url.path
        }
    }
}
