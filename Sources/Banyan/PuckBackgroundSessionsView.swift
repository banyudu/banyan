import BanyanCore
import SwiftUI

/// One compact sidebar entry for daemon sessions outside the working set, so
/// background work takes neither rows nor shortcuts. A pending ask turns it
/// orange; the list it opens is how such a session joins the sidebar.
struct PuckBackgroundSessionsEntry: View {
    @ObservedObject var store: SessionStore
    @State private var isListPresented = false

    var body: some View {
        let count = store.backgroundPuckSummaries.count
        let askCount = store.backgroundPuckAskCount
        let cleanupCount = store.legacyPuckCleanupCandidates.count
        if store.showsPuckBackgroundEntry {
            Button { isListPresented = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: askCount > 0 ? "questionmark.bubble.fill" : "tray.full")
                        .foregroundStyle(askCount > 0 ? Color.orange : Color.secondary)
                    Text(Self.label(count: count, askCount: askCount, cleanupCount: cleanupCount))
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.banyanPlain)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .help("Puck sessions started outside this sidebar")
            .accessibilityIdentifier(AccessibilityID.sidebarPuckBackground)
            .popover(isPresented: $isListPresented, arrowEdge: .trailing) {
                PuckBackgroundSessionsList(store: store) { isListPresented = false }
            }
        }
    }

    static func label(count: Int, askCount: Int, cleanupCount: Int) -> String {
        if askCount > 0 {
            return askCount == 1 ? "1 background Puck ask" : "\(askCount) background Puck asks"
        }
        if count > 0 {
            return count == 1 ? "1 background Puck session" : "\(count) background Puck sessions"
        }
        return cleanupCount == 1 ? "Review 1 auto-added Puck row" : "Review \(cleanupCount) auto-added Puck rows"
    }
}

/// Background sessions, asks first. Opening one adds it to the working set
/// through the same path a `banyan://puck/<id>` link takes.
struct PuckBackgroundSessionsList: View {
    @ObservedObject var store: SessionStore
    let dismiss: () -> Void

    var body: some View {
        let summaries = store.backgroundPuckSummaries
        let cleanupCount = store.legacyPuckCleanupCandidates.count
        VStack(alignment: .leading, spacing: 8) {
            Text("Background Puck sessions")
                .font(.headline)
            Text("Started by other frontends or background tasks. Opening one adds it to the sidebar; its work and transcript are unchanged.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if cleanupCount > 0 {
                Button(cleanupCount == 1
                       ? "Review 1 row added automatically…"
                       : "Review \(cleanupCount) rows added automatically…") {
                    dismiss()
                    store.isPuckCleanupPresented = true
                }
                .buttonStyle(.link)
                .accessibilityIdentifier(AccessibilityID.sidebarPuckCleanupReview)
            }
            Divider()
            if summaries.isEmpty {
                Text("No background sessions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(summaries, id: \.id) { summary in
                            Button {
                                dismiss()
                                store.openPuckSession(id: summary.id)
                            } label: {
                                PuckBackgroundSessionRow(summary: summary, title: store.backgroundPuckTitle(for: summary))
                            }
                            .buttonStyle(.banyanPlain)
                            .help("Open in the sidebar")
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(12)
        .frame(width: 340)
        .accessibilityIdentifier(AccessibilityID.sidebarPuckBackgroundList)
    }
}

private struct PuckBackgroundSessionRow: View {
    let summary: PuckSessionSummary
    let title: String

    var body: some View {
        let status = PuckSessionStatusPolicy.status(for: summary)
        HStack(spacing: 8) {
            Text(status.emoji)
                .font(.system(size: 12))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(detail(status: status))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private func detail(status: SessionStatus) -> String {
        if let approval = summary.pendingApproval { return "Approval requested: \(approval.tool)" }
        if let question = summary.pendingQuestion?.questions.first {
            return "Question: \(question.header.isEmpty ? question.question : question.header)"
        }
        return "\(status.label) · \(summary.provider)/\(summary.model)"
    }
}

/// Removes rows earlier builds added for every listed daemon session. Their
/// origin is unknown, so the user picks; nothing is preselected.
struct PuckCleanupSheet: View {
    @EnvironmentObject private var store: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []

    var body: some View {
        let candidates = store.legacyPuckCleanupCandidates
        let keptCount = store.legacyPuckSessionIDs.count - candidates.count
        VStack(alignment: .leading, spacing: 12) {
            Text("Review Automatically Added Puck Rows")
                .font(.headline)
            Text("Earlier versions of Banyan added every puckd session to the sidebar. Choose the rows to remove. Removing a row only hides it here: its puckd session, transcript, and any running turn are untouched, and it can be opened again from Background Puck sessions.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Select All") { selection = Set(candidates.map(\.id)) }
                    .accessibilityIdentifier(AccessibilityID.puckCleanupSelectAll)
                Button("Select None") { selection = [] }
                Spacer()
                Text("\(selection.count) of \(candidates.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            List(candidates, id: \.id) { session in
                Toggle(isOn: binding(for: session.id)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.displayTitle).lineLimit(1)
                        Text("\(session.projectName) · \(session.status.label) · \(session.updatedAt.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .frame(minHeight: 240)
            if keptCount > 0 {
                Text(keptCount == 1
                     ? "1 row you named, selected, or that belongs to a workflow or session tree is kept and not listed."
                     : "\(keptCount) rows you named, selected, or that belong to a workflow or session tree are kept and not listed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(selection.count == 1 ? "Remove 1 Row" : "Remove \(selection.count) Rows") {
                    store.removeLegacyPuckRows(ids: selection)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection.isEmpty)
                .accessibilityIdentifier(AccessibilityID.puckCleanupRemove)
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
        .accessibilityIdentifier(AccessibilityID.puckCleanupSheet)
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(id) },
            set: { isOn in
                if isOn { selection.insert(id) } else { selection.remove(id) }
            }
        )
    }
}
