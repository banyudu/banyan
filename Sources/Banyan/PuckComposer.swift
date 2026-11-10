import AppKit
import BanyanCore
import SwiftUI
import UniformTypeIdentifiers

/// The Puck message composer: attachments, queued messages, slash commands,
/// and the field itself. Return sends, or queues while a turn is busy; Esc
/// interrupts the running turn.
struct PuckComposer: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: PuckSession
    let typography: PuckTranscriptTypography
    /// Changes when the detail pane wants keyboard focus back in the field.
    let focusRequest: Int
    @State private var promptHistory = PuckPromptHistory()
    @State private var slashSelection = 0
    @State private var dismissedSlashDraft: String?
    @State private var localFocusRequest = 0
    @State private var isFocused = false

    private var slashSuggestions: [PuckSlashCommand] {
        guard dismissedSlashDraft != session.draft else { return [] }
        return PuckSlashCommand.suggestions(for: session.draft)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = session.daemonError {
                SessionLinkedText(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !session.queuedPrompts.isEmpty {
                queuedPrompts
            }
            if !slashSuggestions.isEmpty {
                slashPopup(slashSuggestions)
            }
            field
            hintRow
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .onChange(of: session.draft) { _, _ in slashSelection = 0 }
    }

    // MARK: Field

    private var field: some View {
        VStack(alignment: .leading, spacing: 8) {
            let attached = session.attachedDraftImages
            if !attached.isEmpty {
                PuckImageThumbnailStrip(
                    paths: attached.map(\.image.path),
                    labels: attached.map { "#\($0.number)" },
                    height: 56
                ) { index in
                    guard attached.indices.contains(index) else { return }
                    session.removeDraftImage(attached[index].image)
                }
            }
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                PuckComposerTextView(
                    text: promptBinding,
                    measuredText: session.draft,
                    placeholder: placeholder,
                    font: typography.nsFont,
                    focusRequest: focusRequest + localFocusRequest,
                    acceptsImages: session.acceptsImages,
                    imageCount: session.draftImages.count,
                    onKey: handle,
                    onImageData: { session.attachImage(pngData: $0) },
                    onImageFiles: { $0.compactMap(session.attachImageFile) },
                    onFocusChange: { focused in isFocused = focused }
                )
                // The field reports a concrete width for every probe it is
                // measured with, so SwiftUI would otherwise pin it to its
                // current width instead of filling the row.
                .frame(maxWidth: .infinity, alignment: .leading)
                .help("Return to send · Shift-Return for a new line · ↑ and ↓ recall sent messages")
                if session.acceptsImages {
                    Button(action: chooseImages) {
                        Image(systemName: "paperclip")
                    }
                    .buttonStyle(.banyanBorderless)
                    .foregroundStyle(.secondary)
                    .help("Attach images")
                    .accessibilityLabel("Attach images")
                }
                Button(action: submit) {
                    Image(systemName: session.isBusyForNewTurn ? "text.append" : "arrow.up.circle.fill")
                }
                .buttonStyle(.banyanBorderless)
                .font(.system(size: session.isBusyForNewTurn ? 16 : 20))
                .help(session.isBusyForNewTurn ? "Queue this message for when the turn finishes" : "Send")
                .disabled(!hasContent)
                .accessibilityLabel(session.isBusyForNewTurn ? "Queue message" : "Send")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isFocused ? Color.accentColor.opacity(0.42) : Color.primary.opacity(0.07),
                    lineWidth: 1
                )
        }
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }

    private var placeholder: String {
        session.isBusyForNewTurn ? "Queue a message for the next turn" : "Ask Puck to do anything"
    }

    private var hintRow: some View {
        HStack(spacing: 12) {
            if session.turnPhase.isTurnActive {
                workingStatus
            } else {
                Text(idleHint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer()
            if let usage = session.timeline.usage {
                Label(usageSummary(usage), systemImage: "chart.bar")
                    .accessibilityIdentifier(AccessibilityID.puckUsage)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private var workingStatus: some View {
        HStack(spacing: 4) {
            if session.turnPhase == .running {
                Text("Working")
                if let start = session.turnStartedAt {
                    Text(start, style: .timer)
                        .monospacedDigit()
                }
                if let activity = session.timeline.activity {
                    Text("· \(activity)")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text(session.turnUnavailableReason ?? session.turnPhase.label)
            }
            Text(session.pendingApproval != nil || session.pendingQuestion != nil
                 ? "· Esc to answer above · Return to queue"
                 : "· Esc to interrupt · Return to queue")
        }
        .lineLimit(1)
        .truncationMode(.tail)
    }

    private var idleHint: String {
        var parts = ["Return to send", "Shift-Return for a new line"]
        if session.acceptsImages { parts.append("paste or drop images") }
        parts.append("/ for commands")
        return parts.joined(separator: " · ")
    }

    private func usageSummary(_ usage: PuckUsage) -> String {
        let total = usage.total
        let cache = total.cachedInputTokens > 0
            ? " · \(total.cachedInputTokens.formatted()) cached"
            : ""
        return "\(total.inputTokens.formatted()) in · \(total.outputTokens.formatted()) out\(cache)"
    }

    // MARK: Queue

    private var queuedPrompts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.queuedPrompts.count == 1
                 ? "1 message queued for when the turn finishes"
                 : "\(session.queuedPrompts.count) messages queued for when the turn finishes")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(session.queuedPrompts) { prompt in
                HStack(spacing: 8) {
                    Image(systemName: "arrow.turn.down.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(prompt.text.isEmpty ? "Image only" : prompt.text)
                        .font(typography.captionFont)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if !prompt.images.isEmpty {
                        Label("\(prompt.images.count)", systemImage: "photo")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button {
                        session.editQueuedPrompt(prompt)
                        localFocusRequest += 1
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.banyanBorderless)
                    .help("Edit this queued message")
                    .accessibilityLabel("Edit queued message")
                    Button {
                        session.removeQueuedPrompt(prompt)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.banyanBorderless)
                    .help("Remove this queued message")
                    .accessibilityLabel("Remove queued message")
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier(AccessibilityID.puckQueuedMessages)
    }

    // MARK: Slash commands

    private func slashPopup(_ commands: [PuckSlashCommand]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(commands.enumerated()), id: \.element) { index, command in
                Button {
                    run(command)
                } label: {
                    HStack(spacing: 10) {
                        Text(command.name)
                            .font(typography.font.weight(index == slashSelection ? .semibold : .regular))
                            .frame(minWidth: 90, alignment: .leading)
                        Text(command.summary)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                    .background(
                        index == slashSelection ? Color.accentColor.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
                .buttonStyle(.banyanPlainLabelOnly)
            }
        }
        .padding(4)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier(AccessibilityID.puckSlashCommands)
    }

    private func run(_ command: PuckSlashCommand) {
        session.draft = ""
        promptHistory.reset()
        localFocusRequest += 1
        switch command {
        case .compact:
            session.compact()
        case .stop:
            if session.turnPhase.isTurnActive {
                session.cancel()
            } else {
                session.infoNotice = "No turn is running."
            }
        case .copy:
            session.copyLatestResponse()
        case .status:
            session.infoNotice = session.statusSummary()
        case .new:
            store.spawnSiblingSession()
        }
    }

    // MARK: Keys

    private var hasContent: Bool {
        !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func handle(_ key: PuckComposerKey) -> Bool {
        let suggestions = slashSuggestions
        switch key {
        case .submit:
            if !suggestions.isEmpty {
                run(suggestions[min(slashSelection, suggestions.count - 1)])
            } else {
                submit()
            }
            return true
        case .escape:
            if !suggestions.isEmpty {
                dismissedSlashDraft = session.draft
                return true
            }
            if session.pendingApproval != nil || session.pendingQuestion != nil {
                session.askFocusRequest += 1
                return true
            }
            if session.turnPhase.isTurnActive {
                session.cancel()
                return true
            }
            return false
        case .tab:
            guard !suggestions.isEmpty else { return false }
            session.draft = suggestions[min(slashSelection, suggestions.count - 1)].name
            return true
        case .upArrow:
            if !suggestions.isEmpty {
                slashSelection = max(slashSelection - 1, 0)
                return true
            }
            return recallPreviousPrompt()
        case .downArrow:
            if !suggestions.isEmpty {
                slashSelection = min(slashSelection + 1, suggestions.count - 1)
                return true
            }
            return recallNextPrompt()
        }
    }

    private func submit() {
        if let command = PuckSlashCommand.exact(session.draft) {
            run(command)
            return
        }
        guard hasContent else { return }
        session.send(session.draft)
        promptHistory.reset()
    }

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose images to attach to the next message"
        guard panel.runModal() == .OK else { return }
        session.appendImageFiles(panel.urls)
        localFocusRequest += 1
    }

    // MARK: History

    private var promptBinding: Binding<String> {
        Binding(
            get: { session.draft },
            set: { value in
                promptHistory.reset()
                session.draft = value
            }
        )
    }

    private var promptHistoryEntries: [String] {
        session.timeline.items.reversed().compactMap { item in
            guard item.role == .user, case .user(let text) = item.content else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    private func recallPreviousPrompt() -> Bool {
        guard promptHistory.isBrowsing
                || session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let prompt = promptHistory.previous(currentDraft: session.draft, prompts: promptHistoryEntries)
        else { return false }
        recall(prompt)
        return true
    }

    private func recallNextPrompt() -> Bool {
        guard let prompt = promptHistory.next() else { return false }
        recall(prompt)
        return true
    }

    /// A recalled message comes back without its images, so attachments
    /// left from the blank draft must not answer its placeholders.
    private func recall(_ prompt: String) {
        session.replaceDraft(text: prompt, images: [])
    }
}
