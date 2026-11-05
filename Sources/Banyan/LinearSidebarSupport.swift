import AppKit
import BanyanCore
import Combine
import SwiftUI
import UniformTypeIdentifiers

enum LinearFocusTarget: Hashable {
    case filter
    case stateFilter
    case issueList
}

enum LinearIssueSortOption: String, CaseIterable, Identifiable {
    case defaultOrder
    case updated
    case priority
    case title

    var id: String { rawValue }

    var label: String {
        switch self {
        case .defaultOrder: return "Default order"
        case .updated: return "Recently updated"
        case .priority: return "Priority"
        case .title: return "Title"
        }
    }
}



struct LinearIssueRow: View {
    let issue: LinearIssueSummary
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(issue.identifier)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .lineLimit(1)
                statusPill
                Spacer(minLength: 0)
            }

            Text(issue.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(2)
                .truncationMode(.tail)

            HStack(spacing: 6) {
                metadataText(issue.projectName, fallback: "No project")
                metadataText(issue.priorityLabel ?? priorityLabel, fallback: nil)
                metadataText(issue.cycleName, fallback: nil)
            }
            .font(.caption2)
            .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 64, alignment: .center)
        .padding(.horizontal, 6)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor)
        } else {
            Color.clear
        }
    }

    private var statusPill: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isSelected ? Color.white : Color.linearHex(issue.state.color))
                .frame(width: 6, height: 6)
            Text(issue.state.name)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption2)
        .frame(maxWidth: 92, alignment: .leading)
        .clipped()
    }

    @ViewBuilder
    private func metadataText(_ value: String?, fallback: String?) -> some View {
        if let value, !value.isEmpty {
            Text(value)
        } else if let fallback {
            Text(fallback)
        }
    }

    private var priorityLabel: String? {
        guard let priority = issue.priority, priority > 0 else { return nil }
        return "P\(priority)"
    }
}

extension LinearIssueSummary {
    func matchesFilterTokens(_ tokens: [String]) -> Bool {
        let haystack = [
            identifier,
            title,
            state.name,
            state.type,
            priority.map { "P\($0)" },
            priorityLabel,
            assigneeName,
            teamKey,
            teamName,
            projectName,
            cycleName,
            labels.map(\.name).joined(separator: " ")
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)

        return tokens.allSatisfy { token in
            haystack.contains(
                token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            )
        }
    }
}

extension LinearWorkflowState {
    var filterKey: String {
        [
            name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current),
            type ?? ""
        ].joined(separator: "|")
    }

    var isDefaultVisibleInLinearList: Bool {
        guard !isOnHoldState else { return false }
        guard let type = type?.lowercased() else { return true }
        return ["triage", "backlog", "unstarted", "started"].contains(type)
    }

    private var isOnHoldState: Bool {
        let normalizedName = name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
        return normalizedName == "onhold"
    }
}

extension LinearIssueListLoadState {
    var isStarting: Bool {
        if case .starting = self {
            return true
        }
        return false
    }

    func isStarting(_ issueID: String) -> Bool {
        if case let .starting(startingIssueID) = self {
            return startingIssueID == issueID
        }
        return false
    }
}
