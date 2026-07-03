import SwiftUI

struct EditSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: BanyanSession

    @State private var title: String
    @State private var tone: SessionTone

    init(session: BanyanSession) {
        self.session = session
        _title = State(initialValue: session.title)
        _tone = State(initialValue: session.tone)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit Session")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Title", text: $title)
                Picker("Tone", selection: $tone) {
                    ForEach(SessionTone.allCases) { tone in
                        Text(tone.label).tag(tone)
                    }
                }
                TextField("Working Directory", text: .constant(session.cwd))
                    .disabled(true)
                TextField("Command", text: .constant(session.command.isEmpty ? "Interactive shell" : session.command))
                    .disabled(true)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    session.mark(tone: tone, title: title)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .accessibilityIdentifier(AccessibilityID.editSessionSheet)
    }
}
