import SwiftUI

struct AddSessionDraft: Identifiable {
    enum Kind {
        case sibling
        case child(parentID: String, parentTitle: String)

        var heading: String {
            switch self {
            case .sibling:
                return "New Session"
            case .child:
                return "New Child Session"
            }
        }

        var parentSessionID: String? {
            switch self {
            case .sibling:
                return nil
            case .child(let parentID, _):
                return parentID
            }
        }

        var parentTitle: String? {
            switch self {
            case .sibling:
                return nil
            case .child(_, let parentTitle):
                return parentTitle
            }
        }
    }

    let id = UUID()
    let kind: Kind
    let initialCWD: String

    static func sibling(cwd: String = FileManager.default.currentDirectoryPath) -> AddSessionDraft {
        AddSessionDraft(kind: .sibling, initialCWD: cwd)
    }

    @MainActor
    static func child(of session: BanyanSession) -> AddSessionDraft {
        AddSessionDraft(kind: .child(parentID: session.id, parentTitle: session.displayTitle), initialCWD: session.cwd)
    }
}

struct AddSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: SessionStore

    let draft: AddSessionDraft

    @State private var id = ""
    @State private var title = ""
    @State private var cwd: String
    @State private var command = ""
    @State private var tone: SessionTone = .blue

    init(draft: AddSessionDraft = .sibling()) {
        self.draft = draft
        _cwd = State(initialValue: draft.initialCWD)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(draft.kind.heading)
                .font(.title2.weight(.semibold))

            Form {
                if let parentTitle = draft.kind.parentTitle {
                    LabeledContent("Parent") {
                        Text(parentTitle)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
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
                        parentSessionID: draft.kind.parentSessionID,
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
