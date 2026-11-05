import AppKit
import BanyanCore
import Combine
import SwiftUI
import UniformTypeIdentifiers


/// Presents one inbound suggestion and the two things the human can do with it.
///
/// This is the whole of Banyan's half of the suggestion channel: the policy that
/// decided this issue was worth raising lives in whatever script called
/// `banyanctl suggest`. The command is shown verbatim rather than summarised,
/// because approving runs it — the user should be able to read what they are
/// agreeing to before they agree to it.
///
/// While the banner is on screen the pending decision can also be answered from
/// the keyboard (`SuggestionShortcuts`): the banner owns the monitor, so the
/// chords are live exactly as long as there is something to answer.
struct SuggestionBanner: View {
    let suggestion: InboundSuggestion
    let onApprove: () -> Void
    let onDismiss: () -> Void
    /// Resolves a Linear issue id to the URL the host opens it at. The banner
    /// renders the ids it is given (`suggestion.title`, `suggestion.target`) as
    /// links through this, so an id means the same destination it does in the
    /// command palette.
    let issueURL: (String) -> URL?

    /// Installed on appear and torn down on disappear, matching the lifetime of
    /// the pending suggestion this banner is showing.
    @State private var shortcutMonitor: SuggestionShortcutMonitor?
    @State private var isTitleLinkHovered = false
    @State private var isTargetLinkHovered = false

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(.yellow)
                    .frame(width: 16, height: 16)

                titleLabel

                Spacer(minLength: 4)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.banyanPlain)
                .accessibilityIdentifier(AccessibilityID.sidebarSuggestionDismiss)
                .help("Dismiss this suggestion (\(SuggestionShortcuts.dismissDisplay))")
            }

            if let detail = suggestion.detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(suggestion.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                Button("Run \(SuggestionShortcuts.approveDisplay)", action: onApprove)
                    .accessibilityIdentifier(AccessibilityID.sidebarSuggestionApprove)
                    .accessibilityLabel("Run")
                    .help("Run this suggestion (\(SuggestionShortcuts.approveDisplay))")
                if let target = suggestion.target {
                    Button {
                        if let url = issueURL(target) { openURL(url) }
                    } label: {
                        Text(target)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .underline(isTargetLinkHovered)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .banyanButtonHoverEffect(.labelOnly) { isTargetLinkHovered = $0 }
                    .accessibilityIdentifier(AccessibilityID.sidebarSuggestionTarget)
                    .accessibilityLabel("Open \(target) in Linear")
                    .help("Open \(target) in Linear")
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.banyanBordered)
            .controlSize(.small)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier(AccessibilityID.sidebarSuggestion)
        .onAppear {
            let monitor = SuggestionShortcutMonitor()
            shortcutMonitor = monitor
            monitor.start()
        }
        .onDisappear {
            shortcutMonitor?.stop()
            shortcutMonitor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .suggestionApprove)) { _ in
            onApprove()
        }
        .onReceive(NotificationCenter.default.publisher(for: .suggestionDismiss)) { _ in
            onDismiss()
        }
    }

    /// The title, with a leading issue id (`ENG-12355: …`) rendered as a link
    /// into Linear. Titles that do not lead with an id stay plain text.
    ///
    /// The id and the text after it are one `Text` rather than a link beside a
    /// label, because two sibling views wrap independently: the label would
    /// wrap inside its own, narrower frame, starting every line after the first
    /// indented under the id instead of back at the card's leading edge.
    @ViewBuilder
    private var titleLabel: some View {
        if let split = leadingIssueID {
            Text(linkedTitle(split))
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .onHover { isTitleLinkHovered = $0 }
        } else {
            Text(suggestion.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The title with its leading id linked into Linear, so a click on the id
    /// opens the issue while the rest of the title stays inert text. The id
    /// keeps the title's own colour instead of taking the link tint, and
    /// underlines on hover like the card's other link — that hover is the whole
    /// title's, since a `Text` cannot report which run the pointer is over.
    private func linkedTitle(_ split: (id: String, remainder: String)) -> AttributedString {
        var idRun = AttributedString(split.id)
        idRun.link = issueURL(split.id)
        idRun.foregroundColor = .primary
        if isTitleLinkHovered {
            idRun.underlineStyle = .single
        }
        return idRun + AttributedString(split.remainder)
    }

    /// Splits a title like `ENG-12355: Design proposal` into the leading issue
    /// id and the text that follows it, so only the id becomes a link. Returns
    /// nil when the title has no id, or the id is not at the start.
    private var leadingIssueID: (id: String, remainder: String)? {
        guard let id = LinearIssueReference.issueID(in: suggestion.title),
              let range = suggestion.title.range(of: id),
              range.lowerBound == suggestion.title.startIndex else {
            return nil
        }
        return (id, String(suggestion.title[range.upperBound...]))
    }
}

/// The two ways to answer a pending suggestion from the keyboard, defined once
/// so the monitor that swallows the chord and the tooltip that advertises it
/// cannot drift apart.
enum SuggestionShortcuts {
    static let approveDisplay = "⌘⇧↩"
    static let dismissDisplay = "⌘⇧⌫"

    enum Match {
        case approve
        case dismiss
    }

    /// `⌘⇧↩` or `⌘⇧⌫` with no other modifiers, and not an auto-repeat. Return
    /// and keypad Enter are treated alike, as are the two Delete keys.
    static func match(_ event: NSEvent) -> Match? {
        matches(keyCode: event.keyCode, modifiers: event.modifierFlags, isRepeat: event.isARepeat)
    }

    static func matches(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        isRepeat: Bool
    ) -> Match? {
        guard !isRepeat else { return nil }
        let relevant = modifiers.intersection([.command, .shift, .control, .option])
        guard relevant == [.command, .shift] else { return nil }
        switch keyCode {
        case 36, 76: return .approve
        case 51, 117: return .dismiss
        default: return nil
        }
    }
}

extension Notification.Name {
    /// Posted when the suggestion banner's shortcut monitor swallows `⌘⇧↩`.
    static let suggestionApprove = Notification.Name("banyan.suggestion.approve")
    /// Posted when the suggestion banner's shortcut monitor swallows `⌘⇧⌫`.
    static let suggestionDismiss = Notification.Name("banyan.suggestion.dismiss")
}

/// Swallows `⌘⇧↩` / `⌘⇧⌫` while a suggestion banner is on screen so the pending
/// decision can be answered without reaching for the mouse.
///
/// A focused terminal consumes keystrokes before SwiftUI's key equivalents run,
/// so this has to be an event monitor rather than a `.keyboardShortcut` on the
/// buttons. It is installed only for as long as the banner is visible, so the
/// chords are never hijacked when there is nothing to answer.
final class SuggestionShortcutMonitor {
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let match = SuggestionShortcuts.match(event) else { return event }
            NotificationCenter.default.post(
                name: match == .approve ? .suggestionApprove : .suggestionDismiss,
                object: nil
            )
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
