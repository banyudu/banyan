import AppKit
import BanyanCore
import SwiftUI

struct CommandPaletteItem: Identifiable {
    let id: String
    let category: String
    let title: String
    let detail: String?
    let shortcut: String?
    let action: () -> Void
}

private struct ScoredCommandItem {
    let score: Int
    let offset: Int
    let item: CommandPaletteItem
}

struct CommandPaletteView: View {
    let items: [CommandPaletteItem]
    let onDismiss: () -> Void
    let onQueryChange: (String) -> Void

    @State private var query = ""
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    private var filteredItems: [CommandPaletteItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        let scoredItems: [ScoredCommandItem] = items
            .enumerated()
            .compactMap { entry in
                let offset = entry.offset
                let item = entry.element
                guard let score = Self.matchScore(query, item: item) else { return nil }
                return ScoredCommandItem(score: score, offset: offset, item: item)
            }
        return scoredItems
            .sorted { (lhs: ScoredCommandItem, rhs: ScoredCommandItem) in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.offset < rhs.offset
            }
            .map(\.item)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Type a command or open a Linear/GitHub target", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16))
                        .focused($isSearchFocused)
                        .onSubmit(executeSelection)
                        .onExitCommand(perform: onDismiss)
                        .accessibilityIdentifier("banyan.commandPalette.search")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                if filteredItems.isEmpty {
                    ContentUnavailableView(
                        "No Matching Commands",
                        systemImage: "magnifyingglass",
                        description: Text("Try a command, session title, Linear ID, or GitHub PR.")
                    )
                    .frame(height: 180)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                    commandRow(item, isSelected: index == selectedIndex)
                                        .id(item.id)
                                        .onTapGesture {
                                            selectedIndex = index
                                            executeSelection()
                                        }
                                }
                            }
                            .padding(8)
                        }
                        .frame(maxHeight: 430)
                        .onChange(of: selectedIndex) { _, index in
                            guard filteredItems.indices.contains(index) else { return }
                            withAnimation(.easeOut(duration: 0.08)) {
                                proxy.scrollTo(filteredItems[index].id, anchor: .center)
                            }
                        }
                    }
                }
            }
            .frame(width: 650)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15))
            }
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .accessibilityIdentifier("banyan.commandPalette")
        }
        .onAppear {
            selectedIndex = 0
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
            onQueryChange(query)
        }
        .onMoveCommand { direction in
            guard !filteredItems.isEmpty else { return }
            switch direction {
            case .down:
                selectedIndex = min(selectedIndex + 1, filteredItems.count - 1)
            case .up:
                selectedIndex = max(selectedIndex - 1, 0)
            default:
                break
            }
        }
    }

    private func commandRow(_ item: CommandPaletteItem, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(item.category)
                    if let detail = item.detail, !detail.isEmpty {
                        Text("·")
                        Text(detail)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
            }
        }
        .contentShape(Rectangle())
    }

    private func executeSelection() {
        guard filteredItems.indices.contains(selectedIndex) else { return }
        let item = filteredItems[selectedIndex]
        onDismiss()
        item.action()
    }

    private static func matchScore(_ query: String, item: CommandPaletteItem) -> Int? {
        let searchable = [item.category, item.title, item.detail ?? ""]
            .joined(separator: " ")
            .lowercased()
        let tokens = query.lowercased().split(whereSeparator: \ .isWhitespace)
        var score = 0
        var cursor = searchable.startIndex
        for token in tokens {
            let token = String(token)
            guard let range = searchable.range(of: token, range: cursor..<searchable.endIndex) else {
                guard searchable.contains(token) else { return nil }
                score += 5
                continue
            }
            score += 20
            if range.lowerBound == searchable.startIndex { score += 10 }
            score -= searchable.distance(from: searchable.startIndex, to: range.lowerBound)
            cursor = range.upperBound
        }
        return score
    }
}

enum CommandPaletteTargetResolver {
    static func linearIssueID(in query: String) -> String? {
        LinearIssueReference.issueID(in: query)
    }

    static func pullRequestURL(in query: String, fallback: URL?) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), isGitHubPullRequestURL(url) {
            return url
        }

        guard let hash = trimmed.lastIndex(of: "#"),
              let number = Int(trimmed[trimmed.index(after: hash)...]),
              number > 0 else {
            return nil
        }

        let repository: String
        let prefix = trimmed[..<hash].trimmingCharacters(in: .whitespacesAndNewlines)
        if prefix.isEmpty {
            guard let fallback,
                  let components = URLComponents(url: fallback, resolvingAgainstBaseURL: false) else {
                return nil
            }
            let path = components.path.split(separator: "/").map(String.init)
            guard path.count >= 2 else { return nil }
            repository = path.prefix(2).joined(separator: "/")
        } else {
            let parts = prefix.split(separator: "/")
            guard parts.count == 2 else { return nil }
            repository = parts.map(String.init).joined(separator: "/")
        }

        return URL(string: "https://github.com/\(repository)/pull/\(number)")
    }

    private static func isGitHubPullRequestURL(_ url: URL) -> Bool {
        guard url.host?.lowercased() == "github.com" else { return false }
        let parts = url.path.split(separator: "/")
        return parts.count >= 4 && parts[2].lowercased() == "pull" && Int(parts[3]) != nil
    }
}
