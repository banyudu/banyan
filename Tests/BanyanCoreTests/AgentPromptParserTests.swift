import Foundation
import Testing
@testable import BanyanCore

// The captures below are real `tmux capture-pane -p -J` output from Claude Code,
// Codex and OpenCode, with local paths generalized. Trailing padding is preserved
// where it matters, because the parser finds a list by the column its labels start
// at and pane width is what produces that column.

@Test func parserReadsClaudeCodePermissionDialog() throws {
    let prompt = try #require(AgentPromptParser.parse(visibleText: claudePermissionDialog))

    #expect(prompt.question == "Do you want to proceed?")
    #expect(prompt.options.map(\.label) == [
        "Yes",
        "Yes, and don’t ask again for: rm *",
        "No"
    ])
    #expect(prompt.options.map(\.acceptsNumberKey) == [true, true, true])
    #expect(prompt.options.map(\.index) == [1, 2, 3])
    #expect(prompt.selectedIndex == 1)
    // The command being approved is the part a remote answerer actually needs;
    // "Do you want to proceed?" reads identically for every one of them.
    #expect(prompt.context.contains("rm -f sample.txt && ls sample.txt 2>&1"))
    #expect(prompt.context.contains("Bash command"))
}

@Test func parserTracksWhichOptionIsHighlighted() throws {
    let moved = claudePermissionDialog
        .replacingOccurrences(of: " ❯ 1. Yes", with: "   1. Yes")
        .replacingOccurrences(of: "   3. No", with: " ❯ 3. No")
    let prompt = try #require(AgentPromptParser.parse(visibleText: moved))

    #expect(prompt.selectedIndex == 3)
    #expect(prompt.options.count == 3)
}

@Test func parserReadsUnnumberedCursorList() throws {
    // Claude's trust dialog marks only the highlighted row, so a rule that needs a
    // marker per row would read this as a list of one.
    let prompt = try #require(AgentPromptParser.parse(visibleText: claudeTrustDialog))

    #expect(prompt.options.map(\.label) == ["No, exit", "Yes, I trust this folder"])
    #expect(prompt.options.map(\.acceptsNumberKey) == [false, false])
    #expect(prompt.selectedIndex == 1)
    #expect(prompt.question.hasPrefix("Quick safety check: Is this a project you created or one you trust?"))
    // The question soft-wraps across three rendered rows and has to come back whole.
    #expect(prompt.question.hasSuffix("take a moment to review what's in this folder first."))
}

@Test func parserReadsCodexPickerWithoutAQuestionMark() throws {
    // A numbered list is unambiguous by itself, so Codex phrasing its heading as a
    // statement must not cost the user their options.
    let prompt = try #require(AgentPromptParser.parse(visibleText: codexUpdatePicker))

    #expect(prompt.options.map(\.label) == [
        "Update now (runs `npm install -g @openai/codex`)",
        "Skip",
        "Skip until next version"
    ])
    #expect(prompt.options.map(\.acceptsNumberKey) == [true, true, true])
    #expect(prompt.question.contains("Update available! 0.153.4 -> 0.154.0"))
}

@Test func parserRefusesOpenCodeOverlayItRendersOverTheTranscript() {
    // OpenCode draws its model picker on top of the conversation, so the capture
    // interleaves both. No parse of this is trustworthy, and a wrong row in a
    // picker is exactly the failure this feature cannot afford.
    #expect(AgentPromptParser.parse(visibleText: openCodeModelPicker) == nil)
}

@Test func parserRefusesOpenCodeSlashCommandAutocomplete() {
    // An autocomplete list is not a question the agent is blocked on.
    #expect(AgentPromptParser.parse(visibleText: openCodeSlashAutocomplete) == nil)
}

@Test func parserRefusesUntouchedPrompt() {
    #expect(AgentPromptParser.parse(visibleText: freshClaudePane) == nil)
}

@Test func parserRefusesClearedSessionHoldingAnOldQuestion() {
    // `/clear` wipes the screen but not tmux's scrollback. A question up there is
    // not answerable, and the empty `❯` input row below it is not an option list.
    let cleared = ([
        "⏺ User answered Claude's questions:",
        "  ⎿  · Which branch should I merge to main and deploy? → feature/TASK-123",
        "",
        "⏺ Merged as c7395cd.",
        ""
    ] + [freshClaudePane]).joined(separator: "\n")
        .replacingOccurrences(
            of: "─────────────────────────────────────── ↯ ─",
            with: "❯ /clear\n\n─────────────────────────────────────── ↯ ─"
        )

    #expect(AgentPromptParser.parse(visibleText: cleared) == nil)
}

@Test func parserRefusesASingleTypedPrompt() {
    // One `❯ ship it` row is a prompt the user typed, not a list to choose from.
    let asking = freshClaudePane.replacingOccurrences(
        of: "─────────────────────────────────────── ↯ ─",
        with: [
            "❯ ship it",
            "",
            "⏺ Do you want me to force-push over the remote branch?",
            "",
            "─────────────────────────────────────── ↯ ─"
        ].joined(separator: "\n")
    )

    #expect(AgentPromptParser.parse(visibleText: asking) == nil)
}

@Test func parserRefusesAnUnnumberedListWithNoQuestion() {
    // Without numbering, the question mark is the only evidence that aligned rows
    // are answers rather than output that happens to line up.
    let text = [
        "  Recently edited files",
        "",
        " ❯ ControlServer.swift",
        "   SessionStore.swift",
        ""
    ].joined(separator: "\n")

    #expect(AgentPromptParser.parse(visibleText: text) == nil)
}

@Test func parserRefusesAListNumberedOutOfOrder() {
    let text = [
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   3. No",
        ""
    ].joined(separator: "\n")

    #expect(AgentPromptParser.parse(visibleText: text) == nil)
}

// MARK: - Footprint

@Test func footprintSurvivesCursorMovementAndPaneWidth() throws {
    let base = try #require(AgentPromptParser.parse(visibleText: claudePermissionDialog))
    let moved = try #require(AgentPromptParser.parse(visibleText: claudePermissionDialog
        .replacingOccurrences(of: " ❯ 1. Yes", with: "   1. Yes")
        .replacingOccurrences(of: "   3. No", with: " ❯ 3. No")))
    let repadded = try #require(AgentPromptParser.parse(visibleText: claudePermissionDialog
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0 + "    " }
        .joined(separator: "\n")))

    // Answering moves the cursor, and a resize repaints every row; neither changes
    // which question is on screen.
    #expect(moved.footprint == base.footprint)
    #expect(repadded.footprint == base.footprint)
}

@Test func footprintChangesWhenTheCommandBehindTheSameQuestionChanges() throws {
    let first = try #require(AgentPromptParser.parse(visibleText: claudePermissionDialog))
    let second = try #require(AgentPromptParser.parse(visibleText: claudePermissionDialog
        .replacingOccurrences(of: "rm -f sample.txt && ls sample.txt 2>&1", with: "rm -rf build && ls build 2>&1")))

    // Both dialogs ask "Do you want to proceed?" with identical options. If the
    // command did not reach the footprint, a slow tap approving the first would
    // silently approve the second.
    #expect(first.question == second.question)
    #expect(first.options == second.options)
    #expect(first.footprint != second.footprint)
}

@Test func footprintChangesWhenAnOptionLabelChanges() throws {
    let first = try #require(AgentPromptParser.parse(visibleText: claudePermissionDialog))
    let second = try #require(AgentPromptParser.parse(visibleText: claudePermissionDialog
        .replacingOccurrences(of: "   3. No", with: "   3. No, and tell Claude what to do differently")))

    #expect(first.footprint != second.footprint)
}

// MARK: - Fixtures

/// Real Claude Code v2.1.273 permission dialog, captured from a pane 100 columns
/// wide. Rendered on the alternate screen; `capture-pane -p -J` reads it fine.
private let claudePermissionDialog = [
    "❯ Run the shell command: rm -f sample.txt                                                           ",
    "",
    "  Listed 1 directory (ctrl+o to expand)                                                             ",
    "",
    "⏺ Bash(rm -f sample.txt && ls sample.txt 2>&1)",
    "  ⎿  Waiting…                                                                                     ",
    "",
    "────────────────────────────────────────────────────────────────────────────────────────────────────",
    " Bash command                                                                                       ",
    "                                         ",
    "   rm -f sample.txt && ls sample.txt 2>&1                                                           ",
    "   Delete sample.txt                                                           ",
    "                                 ",
    " Do you want to proceed?                                                                          ",
    " ❯ 1. Yes                               ",
    "   2. Yes, and don’t ask again for: rm *",
    "   3. No                                ",
    "                             ",
    " Esc to cancel · Tab to amend"
].joined(separator: "\n")

/// Real Claude Code workspace-trust dialog: only the highlighted row carries a
/// glyph, and the question soft-wraps across three rows.
private let claudeTrustDialog = [
    "────────────────────────────────────────────────────────────────────────────────────────────────────",
    " Accessing workspace:",
    "",
    " /tmp/example/capture",
    "",
    " Quick safety check: Is this a project you created or one you trust? (Like your own code, a",
    " well-known open source project, or work from your team). If not, take a moment to review what's in",
    " this folder first.",
    "",
    " Claude Code'll be able to read, edit, and execute files here.",
    "",
    " Security guide",
    "",
    " ❯ No, exit",
    "   Yes, I trust this folder",
    "",
    " Enter to confirm · Esc to cancel"
].joined(separator: "\n")

/// Real Codex 0.153.4 update picker: `›` cursor, numbered rows, and a heading that
/// is a statement rather than a question.
private let codexUpdatePicker = [
    "",
    "  ✨ Update available! 0.153.4 -> 0.154.0",
    "",
    "  Release notes: https://github.com/openai/codex/releases/latest",
    "",
    "› 1. Update now (runs `npm install -g @openai/codex`)",
    "  2. Skip",
    "  3. Skip until next version",
    "",
    "  Press enter to continue"
].joined(separator: "\n")

/// Real OpenCode model picker. It is drawn as an overlay, so the capture holds the
/// picker and the transcript underneath it on the same rows.
private let openCodeModelPicker = [
    "  ┃",
    "  ┃  $ echo hello",
    "  ┃",
    "  ┃  hello",
    "  ┃                     Select model                                     esc",
    "",
    "     hello              Search",
    "",
    "     ▣  Dpsk-Flash ·    Qwen2.5-Coder-32B-Instruct",
    "                        Llama-3.1-8B-Instruct",
    "",
    "                        OpenCode Go",
    "                      ● DeepSeek V4.1 Flash",
    "                        Muse Spark 1.3 Contributor",
    "                        Hy4 preview",
    "  ┃                     GLM-5.3-Flash",
    "  ┃                     Qwen3.8 Flash",
    "  ┃",
    "  ┃  Dpsk-Flash · De    Connect provider ctrl+a  Favorite ctrl+f",
    "  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀                                                            ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀",
    "   /tmp/example/capture                                    11.9K (1%) · $ctrl+p"
].joined(separator: "\n")

/// Real OpenCode slash-command autocomplete — a list, but not a question.
private let openCodeSlashAutocomplete = [
    "  ┃ /models                Switch model                                                          ┃",
    "  ┃ /pricing_refresh       Refresh the local runtime pricing snapshot from models.dev.           ┃",
    "  ┃ /tokens_session_all    Token + deterministic cost summary for current session and all descen ┃",
    "  ┃",
    "  ┃  /models",
    "  ┃",
    "  ┃  Dpsk-Flash · DeepSeek V4.1 Flash OpenCode Go",
    "  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀"
].joined(separator: "\n")

private let freshClaudePane = [
    "╭─── Claude Code v2.1.227 ─────────────────────────────╮",
    "│                            │ Tips for getting started │",
    "│      Welcome back!         │ Run /init to create a    │",
    "│                            │ CLAUDE.md file           │",
    "│         ▐▛███▜▌            │ What's new               │",
    "│      ~/dev/my-project      │ /release-notes for more  │",
    "╰──────────────────────────────────────────────────────╯",
    "",
    "",
    "─────────────────────────────────────── ↯ ─",
    "❯",
    "───────────────────────────────────────────",
    "  Opus 5 (1M context) | ~/dev/my-project | main",
    "  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents"
].joined(separator: "\n")

// MARK: - Gating

@Test func gateOffersNoPromptUnlessTheSupervisorSaysTheSessionIsBlocked() {
    // The dialog is on screen in every one of these. What differs is the
    // supervisor's verdict, and that is what decides whether anyone may answer:
    // a permission dialog left in scrollback after the turn moved on still parses
    // perfectly, and answering it would type into a running agent.
    for status in [SessionStatus.executing, .idle, .review, .running, .subagents,
                   .completed, .failed, .closed, .longRunningShell] {
        #expect(
            AgentPromptGate.prompt(status: status, classifiedText: claudePermissionDialog) == nil,
            "status \(status.rawValue) must not expose a prompt"
        )
    }

    #expect(AgentPromptGate.prompt(status: .asking, classifiedText: claudePermissionDialog) != nil)
    #expect(AgentPromptGate.prompt(status: .needInput, classifiedText: claudePermissionDialog) != nil)
}

@Test func gateOffersNoPromptWhenTheSupervisorTookNoCapture() {
    // No capture means no verdict about any text, so there is nothing to gate on.
    #expect(AgentPromptGate.prompt(status: .asking, classifiedText: nil) == nil)
}
