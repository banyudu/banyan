import BanyanCore
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

    static func sibling(cwd: String) -> AddSessionDraft {
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
    @State private var backend: SessionBackendKind = .terminal
    @State private var command = ""
    @State private var puckProvider = PuckSessionBinding.providers[0]
    @State private var puckAccount = ""
    @State private var puckModel = ""
    @State private var tone: SessionTone = .blue

    init(draft: AddSessionDraft) {
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
                Picker("Runtime", selection: $backend) {
                    Text("Terminal").tag(SessionBackendKind.terminal)
                    Text("Puck").tag(SessionBackendKind.puck)
                    if store.enableNativeCodex {
                        Text("Codex (Native)").tag(SessionBackendKind.codex)
                    }
                }
                .pickerStyle(.segmented)
                switch backend {
                case .codex:
                    Text("Native Codex thread")
                case .terminal:
                    TextField("Command", text: $command)
                case .puck:
                    Picker("Provider", selection: $puckProvider) {
                        ForEach(PuckSessionBinding.providers, id: \.self) { provider in
                            Text(Self.puckProviderLabel(provider)).tag(provider)
                        }
                    }
                    TextField(requiresAccountAndModel ? "API-key account label" : "Account label (optional)",
                              text: $puckAccount)
                    TextField(requiresAccountAndModel ? "API model ID" : "Model (optional)",
                              text: $puckModel)
                }
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
                        launch,
                        cwd: cwd,
                        parentSessionID: draft.kind.parentSessionID,
                        id: id.isEmpty ? nil : id,
                        title: title.isEmpty ? nil : title,
                        tone: tone
                    )
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(launchError != nil)
                .help(launchError ?? "Start the session")
            }
        }
        .padding(24)
        .frame(width: 520)
        .accessibilityIdentifier(AccessibilityID.addSessionSheet)
    }

    private var launch: SessionLaunchSpec {
        switch backend {
        case .codex:
            return .codex(.init())
        case .terminal:
            return .terminal(command: command)
        case .puck:
            return .puck(PuckSessionBinding(provider: puckProvider, account: puckAccount, model: puckModel))
        }
    }

    private var launchError: String? {
        if backend == .codex && !store.enableNativeCodex { return "Enable native Codex in Preferences first" }
        guard case .puck(let binding) = launch else { return nil }
        return binding.validationError
    }

    private var requiresAccountAndModel: Bool {
        PuckSessionBinding.requiresAccountAndModel(provider: puckProvider)
    }

    private static func puckProviderLabel(_ provider: String) -> String {
        switch provider {
        case "codex": return "Codex"
        case "opencode-go": return "OpenCode Go"
        case "anthropic": return "Anthropic API (billed)"
        case "gemini": return "Gemini AI Studio API (billed)"
        default: return provider
        }
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
