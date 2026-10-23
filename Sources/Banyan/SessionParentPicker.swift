import SwiftUI

/// Mounted only after an explicit Move action. Keeping the destination lookup
/// out of SessionRow avoids scanning the whole catalog on every row update.
struct SessionParentPicker: View {
    @ObservedObject var session: BanyanSession
    let loadTargets: () -> [SidebarSessionItem]
    let move: (String?) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var targets: [SidebarSessionItem] = []
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Move session").font(.headline)
            Text(session.displayTitle).lineLimit(2)
            Text("Choose a parent in this project.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                Button("Root level") { choose(nil) }
                    .disabled(session.parentSessionID == nil)
                ForEach(targets) { target in
                    Button { choose(target.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(target.session.displayTitle).lineLimit(2)
                            Text(target.id).font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.leading, CGFloat(target.depth) * 18)
                    }
                    .disabled(session.parentSessionID == target.id)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420, height: 440)
        .task { targets = loadTargets() }
        .alert("Could not move session", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK") { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func choose(_ parentID: String?) {
        do {
            // The store revalidates live relationships: a target can close or
            // move while this snapshot is visible.
            try move(parentID)
            dismiss()
        } catch {
            self.error = error.localizedDescription
            targets = loadTargets()
        }
    }
}
