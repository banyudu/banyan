import Foundation
import Testing
@testable import BanyanCore

/// Workit wakes a finished turn only when the agent's input box is empty.
/// These shapes come from captured panes; only names, paths and numbers are
/// anonymized.
@Suite struct SessionWorkflowComposerTests {
    private static let esc = "\u{1B}"
    private static let rule = "\(esc)[38;5;66m" + String(repeating: "─", count: 48)
    private static let statusLine = "\(esc)[39m  \(esc)[38;5;145mOpus\(esc)[39m \(esc)[38;5;145m5.5\(esc)[39m "
        + "\(esc)[38;5;145m|\(esc)[39m \(esc)[38;5;145m10% ctx\(esc)[39m \(esc)[38;5;145m|\(esc)[39m "
        + "\(esc)[38;5;145mTASK-123 · PR #123\(esc)[39m"
    private static let modeRow = "  \(esc)[38;5;210m⏵⏵\(esc)[39m \(esc)[38;5;210mbypass permissions on"
        + "\(esc)[38;5;145m (shift+tab to cycle)\(esc)[39m \(esc)[38;5;145m·\(esc)[39m \(esc)[38;5;145mPR\(esc)[39m "
        + "\(esc)[4m\(esc)[38;5;222m\(esc)]8;id=a1;https://example.com/pull/123\(esc)\\#123\(esc)]8;;\(esc)\\\(esc)[0m"

    private static func claudePane(composer: String, footer: [String] = [SessionWorkflowComposerTests.statusLine, SessionWorkflowComposerTests.modeRow, "", ""]) -> String {
        (["  This turn has ended.", "", "✻ Baked for 10s · done 2:03 PM", "", rule, composer, rule] + footer)
            .joined(separator: "\n")
    }

    /// The prompt suggestion Claude shows after a finished turn: every word faint.
    private static let suggestion = "\(esc)[39m❯\u{00A0}\(esc)[2mcheck\(esc)[0m \(esc)[2mCI\(esc)[0m \(esc)[2mon\(esc)[0m \(esc)[2m#123\(esc)[0m"

    @Test func claudeEmptyInputBoxWithStatusLinePermitsWake() {
        let pane = Self.claudePane(composer: "\(Self.esc)[39m❯\u{00A0}" + String(repeating: " ", count: 40))
        #expect(SessionWorkflowPolicy.hasEmptyInput(pane))
        #expect(SessionWorkflowPolicy.canWake(status: .needInput, isSuspended: false, isFrozen: false,
            isDeepSuspended: false, hasObservation: true, isAgent: true,
            hasEmptyInput: SessionWorkflowPolicy.hasEmptyInput(pane)))
    }

    /// A pane taller than Claude's inline output keeps blank rows under the
    /// footer; they must not push the input box out of the composer window.
    @Test func trailingBlankRowsDoNotHideTheInputBox() {
        let blanks = Array(repeating: "", count: 20)
        let pane = Self.claudePane(composer: "❯\u{00A0}", footer: [Self.statusLine, Self.modeRow] + blanks)
        #expect(SessionWorkflowPolicy.hasEmptyInput(pane))
        // Blank rows between the composer and later output still count.
        #expect(!SessionWorkflowPolicy.hasEmptyInput(
            Self.claudePane(composer: "❯\u{00A0}", footer: blanks + [Self.modeRow])))
    }

    @Test func claudeFaintSuggestionCountsAsEmptyButTypedTextDoesNot() {
        #expect(SessionWorkflowPolicy.hasEmptyInput(Self.claudePane(composer: Self.suggestion)))
        // Accepted with Tab, the same words are drawn normally: a real draft.
        let accepted = Self.suggestion.replacingOccurrences(of: "\(Self.esc)[2m", with: "")
        #expect(!SessionWorkflowPolicy.hasEmptyInput(Self.claudePane(composer: accepted)))
        // A typed prefix before a faint completion is still a draft.
        #expect(!SessionWorkflowPolicy.hasEmptyInput(Self.claudePane(
            composer: "❯ ch\(Self.esc)[2meck CI\(Self.esc)[0m")))
        // A plain capture cannot show styling, so the text stays a draft.
        let plain = TerminalStyledCapture(Self.claudePane(composer: Self.suggestion)).rows.map(\.text)
            .joined(separator: "\n")
        #expect(!SessionWorkflowPolicy.hasEmptyInput(plain))
    }

    @Test func claudeDialogsAndMultilineDraftsRefuseWake() {
        // Selection rows use ❯ too, but never between the input box rules.
        let dialog = ["Do you want to proceed?", "\(Self.esc)[2m❯ 1. Yes\(Self.esc)[0m", "  2. No", "",
            "Esc to cancel"].joined(separator: "\n")
        #expect(!SessionWorkflowPolicy.hasEmptyInput(dialog))
        let multiline = [Self.rule, "❯\u{00A0}", "  second line", Self.rule, Self.modeRow].joined(separator: "\n")
        #expect(!SessionWorkflowPolicy.hasEmptyInput(multiline))
    }

    @Test func claudeFooterAcceptsStatusLineOnlyAboveKnownHint() {
        let empty = "❯\u{00A0}"
        #expect(SessionWorkflowPolicy.hasEmptyInput(Self.claudePane(composer: empty, footer: ["  ? for shortcuts"])))
        #expect(SessionWorkflowPolicy.hasEmptyInput(Self.claudePane(composer: empty, footer: [])))
        // An overlay below the hint row, a status line with no hint, or a tall
        // block of unknown rows is not the idle footer.
        #expect(!SessionWorkflowPolicy.hasEmptyInput(Self.claudePane(composer: empty,
            footer: [Self.statusLine, Self.modeRow, "  1 background task · ↓ to view"])))
        #expect(!SessionWorkflowPolicy.hasEmptyInput(Self.claudePane(composer: empty, footer: [Self.statusLine])))
        #expect(!SessionWorkflowPolicy.hasEmptyInput(Self.claudePane(composer: empty,
            footer: ["status a", "status b", "status c", "status d", Self.modeRow])))
    }

    @Test func codexAgentsShortcutHintPermitsWake() {
        let footer = "GPT-6.1-Sol xhigh · ~/dev/my-project/.worktrees/task-123 · Context 32% used · weekly 52% left · Main [default]"
        let pane = "Done\n \n› Ask Codex to do anything\n \n  \(footer)\n  ← for agents · ? for shortcuts      "
        #expect(SessionWorkflowPolicy.hasEmptyInput(pane))
        #expect(!SessionWorkflowPolicy.hasEmptyInput(pane.replacingOccurrences(
            of: "› Ask Codex to do anything", with: "› unsent draft")))
        #expect(!SessionWorkflowPolicy.hasEmptyInput(pane.replacingOccurrences(
            of: "← for agents · ? for shortcuts", with: "← for agents · Permission required")))
    }

    @Test func styledCaptureTracksFaintAcrossRowsAndSkipsColorArguments() {
        let capture = TerminalStyledCapture(
            "a\(Self.esc)[2mb\nc\(Self.esc)[22md\(Self.esc)[38;2;2;2;2me\(Self.esc)[48;5;2mf"
            + "\(Self.esc)]8;;https://example.com\u{07}g\(Self.esc)[2;38:2::1:2:3mh\(Self.esc)[mi")
        #expect(capture.rows.map(\.text) == ["ab", "cdefghi"])
        #expect(capture.rows.map(\.solidText) == ["a", "defgi"])
    }
}
