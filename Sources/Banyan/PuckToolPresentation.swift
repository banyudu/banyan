import AppKit
import BanyanCore
import Foundation
import SwiftUI

struct PuckToolDetailBlock: View {
    let title: String
    let text: String
    var language: String?
    var typography: PuckTranscriptTypography = .fallback
    private let presentation: PuckToolTextPresentation

    init(
        title: String,
        text: String,
        language: String? = nil,
        typography: PuckTranscriptTypography = .fallback
    ) {
        self.title = title
        self.text = text
        self.language = language
        self.typography = typography
        presentation = PuckToolTextPresentation(text: text, explicitLanguage: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(typography.captionFont.weight(.semibold))
                .foregroundStyle(.secondary)
            CodeBlockView(
                text: presentation.text,
                language: presentation.languageIdentifier,
                syntaxSections: presentation.syntaxSections,
                font: typography.font,
                previewHeight: previewHeight(for: presentation.text)
            )
        }
    }

    private func previewHeight(for text: String) -> CGFloat {
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return min(220, max(40, CGFloat(lineCount) * typography.detailLineHeight + 16))
    }
}

struct PuckToolPreview {
    let lines: [String]
    let hiddenLineCount: Int
    let language: CodeBlockLanguage?
    let syntaxSections: [CodeBlockSyntaxSection]?
}

struct PuckToolGroupSummary {
    let items: [PuckTimelineItem]

    private var tools: [PuckToolActivity] {
        items.compactMap { item in
            guard case .tool(let tool) = item.content else { return nil }
            return tool
        }
    }

    var id: String { items.first?.id ?? "empty" }
    var isRunning: Bool { tools.contains { $0.state == .running } }
    private var failedCount: Int { tools.filter { $0.state == .failed }.count }
    private var isTruncated: Bool { tools.contains { $0.state == .truncated } }
    private var isCommandGroup: Bool { tools.allSatisfy(\.isCommand) }

    var title: String {
        let count = tools.count
        let noun = isCommandGroup
            ? (count == 1 ? "command" : "commands")
            : (count == 1 ? "tool" : "tools")
        if isRunning {
            return "Running \(count) \(noun)"
        }
        let action = isCommandGroup ? "Ran" : "Used"
        if failedCount > 0 {
            return "\(action) \(count) \(noun) · \(failedCount) failed"
        }
        if isTruncated {
            return "\(action) \(count) \(noun) · truncated"
        }
        return "\(action) \(count) \(noun)"
    }

    var detail: String? {
        var names: [String] = []
        for tool in tools where !names.contains(tool.displayName) {
            names.append(tool.displayName)
        }
        if isCommandGroup && names.count <= 1 { return nil }
        guard !names.isEmpty else { return nil }
        if names.count > 3 {
            return names.prefix(3).joined(separator: ", ") + " +\(names.count - 3) more"
        }
        return names.joined(separator: ", ")
    }

    var tint: Color {
        if !isRunning, failedCount > 0 { return .red.opacity(0.7) }
        return .secondary
    }

    var accessibilityLabel: String {
        [title, detail].compactMap { $0 }.joined(separator: ", ")
    }
}

extension PuckToolActivity {
    var actionLabel: String {
        switch state {
        case .running: "Running"
        case .succeeded, .truncated: "Ran"
        case .failed: "Failed"
        }
    }

    var hasDetails: Bool {
        arguments?.isEmpty == false || !displayOutput.isEmpty
    }

    var displayTitle: String {
        commandText ?? displayName
    }

    var displayName: String {
        let normalized = name.lowercased().replacingOccurrences(of: "-", with: "_")
        switch normalized {
        case "exec_command", "shell", "bash", "run_command", "terminal":
            return "Command"
        case "update_plan", "plan":
            return "Plan"
        case "request_user_input", "question", "ask":
            return "Question"
        case "apply_patch", "patch", "edit":
            return "Patch"
        case "read_file", "read":
            return "Read"
        case "search", "grep", "glob":
            return "Search"
        case "list_files", "list_directory", "ls":
            return "List"
        case "webfetch", "fetch":
            return "Fetch"
        case "write_file", "write":
            return "Write"
        case "view_image":
            return "Image"
        case "spawn_agent", "agent":
            return "Agent"
        case "tool":
            return "Tool"
        default:
            let words = normalized.split(separator: "_")
            guard let first = words.first else { return "Tool" }
            return ([first.capitalized] + words.dropFirst().map(String.init)).joined(separator: " ")
        }
    }

    var isCommand: Bool {
        switch name.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "exec_command", "shell", "bash", "run_command", "terminal":
            return true
        default:
            return false
        }
    }

    private var commandText: String? {
        guard let arguments,
              let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let value = ["cmd", "command", "script"]
            .compactMap { object[$0] }
            .first { $0 is String || $0 is [String] }
        let command: String?
        if let string = value as? String {
            command = string
        } else if let words = value as? [String] {
            command = words.joined(separator: " ")
        } else {
            command = nil
        }
        guard let command else { return nil }
        let singleLine = command.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !singleLine.isEmpty else { return nil }
        return String(singleLine.prefix(400))
    }

    var displayOutput: String {
        displayOutputLines.joined(separator: "\n")
    }

    private var displayOutputLines: [String] {
        var lines: [String] = []
        for rawLine in CommandOutputText.strippingANSIEscapes(output).components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let lower = trimmed.lowercased()
            if lower.hasPrefix("exit code:"),
               Int(trimmed.dropFirst("exit code:".count).trimmingCharacters(in: .whitespaces)) != nil {
                continue
            }
            if ["--- stdout ---", "--- stderr ---", "--- output ---"].contains(lower) {
                continue
            }
            lines.append(line)
        }
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeFirst()
        }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        var compacted: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty,
               compacted.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                continue
            }
            compacted.append(line)
        }
        return compacted
    }

    var preview: PuckToolPreview? {
        let output = displayOutput
        guard !output.isEmpty else { return nil }
        let presentation = PuckToolTextPresentation(text: output)
        let isJSON = presentation.containsJSON
        // Format before clipping so nested results stay readable and the
        // disclosure counts the same lines as the expanded output.
        let lines = (isJSON ? presentation.text : output).components(separatedBy: "\n")
        let limit = isJSON ? 8 : 2
        let visibleLines = Array(lines.prefix(limit))
        var remaining = visibleLines.joined(separator: "\n").count
        let sections = presentation.syntaxSections.map { sections in
            sections.compactMap { section -> CodeBlockSyntaxSection? in
                guard remaining > 0 else { return nil }
                let text = String(section.text.prefix(remaining))
                remaining -= text.count
                return CodeBlockSyntaxSection(text: text, language: section.language)
            }
        }
        return PuckToolPreview(
            lines: visibleLines,
            hiddenLineCount: max(0, lines.count - limit),
            language: isJSON ? presentation.language : nil,
            syntaxSections: sections
        )
    }
}

struct PuckToolStatePresentation {
    let label: String
    let systemImage: String
    let tint: Color
}

extension PuckToolState {
    var presentation: PuckToolStatePresentation {
        switch self {
        case .running:
            PuckToolStatePresentation(label: "Running", systemImage: "arrow.triangle.2.circlepath", tint: .secondary)
        case .succeeded:
            PuckToolStatePresentation(label: "Succeeded", systemImage: "checkmark.circle.fill", tint: .secondary)
        case .failed:
            PuckToolStatePresentation(label: "Failed", systemImage: "xmark.octagon.fill", tint: .red.opacity(0.7))
        case .truncated:
            PuckToolStatePresentation(label: "Truncated", systemImage: "exclamationmark.triangle.fill", tint: .secondary)
        }
    }
}
