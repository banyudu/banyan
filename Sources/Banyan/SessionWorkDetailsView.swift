import BanyanCore
import SwiftUI

@MainActor final class SessionWorkState: ObservableObject {
    @Published private(set) var summary: SessionWorkSummary?

    init(summary: SessionWorkSummary? = nil) { self.summary = summary }

    func update(_ summary: SessionWorkSummary?) {
        guard self.summary != summary else { return }
        self.summary = summary
    }
}

struct SessionWorkStatusButton: View {
    let summary: SessionWorkSummary
    let openSession: (String) -> Void
    @State private var isPresented = false

    private var hasChildSessions: Bool { !summary.descendants.isEmpty }

    private var summaryText: String {
        guard hasChildSessions else { return summary.own.label }
        return summary.own.needsAttention
            ? "\(summary.own.label) · \(summary.groupLabel)" : summary.groupLabel
    }

    var body: some View {
        if hasChildSessions {
            Button { isPresented = true } label: { statusLabel }
                .buttonStyle(.banyanPlainLabelOnly)
                .help("\(summaryText) — show child sessions")
                .accessibilityLabel("Child sessions: \(summaryText)")
                .accessibilityIdentifier("session.\(summary.own.id).workflow")
                .popover(isPresented: $isPresented, arrowEdge: .trailing) {
                    SessionWorkDetailsView(summary: summary) { id in
                        isPresented = false
                        openSession(id)
                    }
                }
        } else {
            statusLabel
                .help(summary.own.workStatusHelp)
                .accessibilityLabel(summary.own.workStatusHelp)
                .accessibilityIdentifier("session.\(summary.own.id).workflow")
        }
    }

    private var statusLabel: some View {
        HStack(spacing: 3) {
            if summary.own.background {
                Image(systemName: "moon").foregroundStyle(.secondary).accessibilityLabel("Background work")
            }
            statusContent
        }
        .font(.caption2)
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var statusContent: some View {
        if summary.descendants.isEmpty {
            ownBadge
        } else {
            if summary.own.needsAttention {
                ownBadge
            }
            ForEach(summary.groupStatuses) { status in
                WorkStatusBadge(category: status.category, count: status.count,
                    label: "\(status.count) \(status.label)")
            }
        }
    }

    private var ownBadge: some View {
        WorkStatusBadge(category: summary.own.badgeCategory,
            emphasized: summary.own.needsAttention, label: summary.own.workStatusHelp,
            text: summary.own.waitingForWorkit ? (summary.own.checkIsDue ? "Check due" : "Waiting") : nil)
    }
}

private struct WorkStatusBadge: View {
    let category: SessionWorkSummary.GroupStatus.Category
    var count: Int? = nil
    var emphasized = false
    let label: String
    var text: String? = nil

    private var tint: Color { emphasized ? .orange : category.tint }

    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: category.systemImage)
                .font(.system(size: 9, weight: .semibold))
            if let count {
                Text("\(count)")
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
            }
            if let text { Text(text).font(.system(size: 9, weight: .medium)) }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 4)
        .frame(height: 16)
        .background(tint.opacity(0.12), in: Capsule())
        .help(label)
        .accessibilityLabel(label)
    }
}

extension SessionWorkSummary.GroupStatus.Category {
    var systemImage: String {
        switch self {
        case .needsYou: "hand.raised.fill"
        case .phase(let phase):
            switch phase {
            case .investigation: "magnifyingglass"
            case .implementation: "hammer.fill"
            case .prOpen: "arrow.triangle.branch"
            case .merged: "arrow.triangle.merge"
            case .verified: "checkmark.seal.fill"
            case .cancelled: "xmark.circle.fill"
            }
        case .kind(let kind):
            switch kind {
            case .working: "gearshape.fill"
            case .waiting: "clock.fill"
            case .blocked: "exclamationmark.triangle.fill"
            case .decision: "questionmark.bubble.fill"
            case .paused: "pause.circle.fill"
            case .verified: "checkmark.seal.fill"
            case .idle: "moon.zzz.fill"
            case .cancelled: "xmark.circle.fill"
            }
        }
    }

    var tint: Color {
        switch self {
        case .needsYou, .kind(.blocked), .kind(.decision): .orange
        case .phase(.verified), .kind(.verified): .green
        case .phase(.cancelled), .kind(.cancelled), .kind(.paused), .kind(.idle): .secondary
        default: .blue
        }
    }
}

extension SessionWorkEntry {
    var badgeCategory: SessionWorkSummary.GroupStatus.Category {
        if waitingForWorkit { .kind(.waiting) }
        else if kind == .idle { .kind(.idle) }
        else if let phase { .phase(phase) } else { .kind(kind) }
    }

    var badgeSystemImage: String { badgeCategory.systemImage }

    var workStatusHelp: String {
        guard waitingForWorkit else { return label }
        var help = "\(label). Agent idle; Workit owns the next check."
        if let checkDueAt {
            help += " Eligible from \(checkDueAt.formatted(date: .abbreviated, time: .shortened))."
            if checkIsDue { help += " Check was due at the last refresh." }
        }
        return help + " The heartbeat checks external progress and resumes this session when action is needed."
    }
}

struct SessionWorkDetailsView: View {
    let summary: SessionWorkSummary
    let openSession: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(summary.descendants) { entry in
                    Button { openSession(entry.id) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            WorkStatusBadge(category: entry.badgeCategory,
                                emphasized: entry.needsAttention, label: entry.workStatusHelp,
                                text: entry.waitingForWorkit ? (entry.checkIsDue ? "Check due" : "Waiting") : nil)
                            Text(entry.title).lineLimit(2).multilineTextAlignment(.leading)
                            if entry.background {
                                Image(systemName: "moon").foregroundStyle(.secondary)
                                    .help("Background work").accessibilityLabel("Background work")
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.banyanBorderless)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 440)
        .padding(12)
        .frame(width: 360)
    }
}
