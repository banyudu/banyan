@testable import Banyan
import Foundation
import Testing

@Test func paletteCommandsParseTitleCommandRunAndWhen() throws {
    let commands = try PaletteCommandLoader.parse("""
    palette_commands:
      - id: work
        title: "Work on {{target}}"
        command: "~/bin/workit {{target}}"
        run: session
        when: issue
      - id: verify
        title: "Verify {{target}}"
        command: "~/bin/verify-linear {{target}}"
        run: background
        when: linear
    """)

    #expect(commands.map(\.id) == ["work", "verify"])
    #expect(commands[0].run == .session)
    #expect(commands[0].when == .issue)
    #expect(commands[1].run == .background)
    #expect(commands[1].when == .linear)
    #expect(commands[0].expandedTitle(target: "ENG-123", query: nil, agent: nil) == "Work on ENG-123")
    #expect(commands[0].expandedCommand(target: "ENG-123", query: nil, agent: nil) == "~/bin/workit ENG-123")
}

@Test func paletteCommandAgentFlagExpandsOnlyWhenPicked() throws {
    let commands = try PaletteCommandLoader.parse("""
    palette_commands:
      - id: work
        title: "Work on {{target}}"
        command: "~/bin/workit {{target}} {{agentFlag}}"
    """)
    let command = commands[0]

    // Auto: the flag disappears so workit keeps its own weighted pick instead of
    // receiving a dangling `--agent`.
    #expect(command.expandedCommand(target: "ENG-123", query: nil, agent: nil) == "~/bin/workit ENG-123 ")

    // Picked: the picker id is the registry key `--agent` resolves.
    #expect(command.expandedCommand(target: "ENG-123", query: nil, agent: "dpsk-flash")
        == "~/bin/workit ENG-123 --agent dpsk-flash")
}

@Test func paletteCommandBareAgentExpandsToTheID() throws {
    let commands = try PaletteCommandLoader.parse("""
    palette_commands:
      - id: review
        title: "Review {{target}}"
        command: "review-linear {{target}} --runner cli {{agent}}"
    """)

    #expect(commands[0].expandedCommand(target: "ENG-1", query: nil, agent: "muse")
        == "review-linear ENG-1 --runner cli muse")
    #expect(commands[0].expandedCommand(target: "ENG-1", query: nil, agent: nil)
        == "review-linear ENG-1 --runner cli ")
}

@Test func paletteCommandAgentPlaceholdersTrimAndTreatBlankAsAuto() throws {
    let commands = try PaletteCommandLoader.parse("""
    palette_commands:
      - id: work
        title: Work
        command: "workit {{agentFlag}}"
    """)

    #expect(commands[0].expandedCommand(target: nil, query: nil, agent: "  dpsk-flash ")
        == "workit --agent dpsk-flash")
    #expect(commands[0].expandedCommand(target: nil, query: nil, agent: "   ") == "workit ")
}

/// A command that does not mention the placeholders stays opaque to the picker.
@Test func paletteCommandWithoutAgentPlaceholdersIgnoresThePick() throws {
    let commands = try PaletteCommandLoader.parse("""
    palette_commands:
      - id: work
        title: Work
        command: "workit {{target}}"
    """)

    #expect(commands[0].expandedCommand(target: "ENG-1", query: nil, agent: "muse") == "workit ENG-1")
}

@Test func paletteCommandsDefaultToSessionAndAlways() throws {
    let commands = try PaletteCommandLoader.parse("""
    palette_commands:
      - id: quick
        title: Quick
        command: echo hi
    """)

    #expect(commands.count == 1)
    #expect(commands[0].run == .session)
    #expect(commands[0].when == .always)
    #expect(commands[0].parent == .root)
}

@Test func paletteCommandsDefaultToRootAndParseCurrent() throws {
    let commands = try PaletteCommandLoader.parse("""
    palette_commands:
      - id: work
        title: "Work on {{target}}"
        command: "~/bin/workit {{target}}"
        parent: current
      - id: verify
        title: "Verify {{target}}"
        command: "~/bin/verify-linear {{target}}"
    """)

    #expect(commands[0].parent == .current)
    #expect(commands[1].parent == .root)
}

@Test func unknownPaletteCommandParentThrows() {
    #expect(throws: Error.self) {
        try PaletteCommandLoader.parse("""
        palette_commands:
          - id: work
            title: Work
            command: echo a
            parent: sibling
        """)
    }
}

@Test func helperSpawnEnvironmentEditsClearInheritedSessionIdentity() {
    // A root spawn must drop `TMUX` as well: `banyanctl` falls back to the
    // enclosing tmux session, which would re-parent to the session the Banyan
    // app itself was launched from.
    let root = SessionStore.helperSpawnEnvironmentEdits(parentSessionID: nil)
    #expect(root.removeKeys == [
        "BANYAN_SESSION_ID", "BANYAN_PARENT_SESSION_ID", "TMUX", "TMUX_PANE"
    ])
    #expect(root.overrides.isEmpty)

    // An explicit parent wins over both fallbacks, so `TMUX` can stay and the
    // helper keeps its context.
    let current = SessionStore.helperSpawnEnvironmentEdits(parentSessionID: "session-42")
    #expect(current.removeKeys == ["BANYAN_SESSION_ID", "BANYAN_PARENT_SESSION_ID"])
    #expect(current.overrides == ["BANYAN_PARENT_SESSION_ID": "session-42"])
}

@Test func paletteCommandsCoexistWithSessionLaunches() throws {
    let commands = try PaletteCommandLoader.parse("""
    session_launches:
      - id: claude
        label: Claude
        command: claude
    palette_commands:
      - id: work
        title: "Work on {{target}}"
        command: "~/bin/workit {{target}}"
    """)

    #expect(commands.map(\.id) == ["work"])
}

@Test func paletteCommandTargetDetectionPrefersLinear() {
    #expect(PaletteCommandTarget.detect(in: "ENG-123") == .linear("ENG-123"))
    #expect(PaletteCommandTarget.detect(in: "verify ENG-456") == .linear("ENG-456"))
    #expect(PaletteCommandTarget.detect(in: "not-an-issue") == nil)
    let github = PaletteCommandTarget.detect(in: "https://github.com/owner/repo/issues/17")
    #expect(github == .github("https://github.com/owner/repo/issues/17"))
}

@Test func paletteCommandWhenFiltersTargets() {
    let linear = PaletteCommandTarget.linear("ENG-123")
    let github = PaletteCommandTarget.github("https://github.com/o/r/issues/1")
    let always = PaletteCommand(id: "a", title: "A", command: "echo", run: .session, when: .always)
    let issue = PaletteCommand(id: "i", title: "I", command: "echo", run: .session, when: .issue)
    let linearOnly = PaletteCommand(id: "l", title: "L", command: "echo", run: .session, when: .linear)
    let githubOnly = PaletteCommand(id: "g", title: "G", command: "echo", run: .session, when: .github)

    #expect(always.matches(target: linear))
    #expect(always.matches(target: github))
    #expect(issue.matches(target: linear))
    #expect(issue.matches(target: github))
    #expect(linearOnly.matches(target: linear))
    #expect(!linearOnly.matches(target: github))
    #expect(!githubOnly.matches(target: linear))
    #expect(githubOnly.matches(target: github))
    #expect(!always.matches(target: nil))
}

@Test func duplicatePaletteCommandIDsThrow() {
    #expect(throws: Error.self) {
        try PaletteCommandLoader.parse("""
        palette_commands:
          - id: work
            title: Work
            command: echo a
          - id: work
            title: Work again
            command: echo b
        """)
    }
    #expect(throws: Error.self) {
        try PaletteCommandLoader.parse("""
        palette_commands:
          - id: work
            title: Work
            command: echo a
            run: teleport
        """)
    }
}

private func paletteTestHome() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-palette-tests-\(UUID().uuidString)")
}

private func writePaletteTestFile(home: URL, name: String, contents: String) {
    let dir = home.appendingPathComponent(".banyan")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
}

@Test func paletteCommandsLoadFromDedicatedPaletteFile() {
    let home = paletteTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    writePaletteTestFile(home: home, name: "palette.yml", contents: """
    palette_commands:
      - id: work
        title: "Work on {{target}}"
        command: "~/bin/workit {{target}}"
        run: background
        when: issue
    """)

    let result = PaletteCommandLoader.load(homeDirectory: home)

    #expect(result.commands.map(\.id) == ["work"])
    #expect(result.diagnostic == nil)
}

@Test func paletteCommandsMergeConfigFileAfterDedicatedFile() {
    let home = paletteTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    writePaletteTestFile(home: home, name: "palette.yml", contents: """
    palette_commands:
      - id: work
        title: Work
        command: echo work
    """)
    writePaletteTestFile(home: home, name: "config.yml", contents: """
    palette_commands:
      - id: verify
        title: Verify
        command: echo verify
    """)

    let result = PaletteCommandLoader.load(homeDirectory: home)

    #expect(result.commands.map(\.id) == ["work", "verify"])
    #expect(result.diagnostic == nil)
}

@Test func paletteCommandsPreferDedicatedFileOnDuplicateIDs() {
    let home = paletteTestHome()
    defer { try? FileManager.default.removeItem(at: home) }
    writePaletteTestFile(home: home, name: "palette.yml", contents: """
    palette_commands:
      - id: work
        title: Work local
        command: echo local
    """)
    writePaletteTestFile(home: home, name: "config.yml", contents: """
    palette_commands:
      - id: work
        title: Work config
        command: echo config
    """)

    let result = PaletteCommandLoader.load(homeDirectory: home)

    #expect(result.commands.map(\.title) == ["Work local"])
    #expect(result.diagnostic?.contains("Duplicate palette command id 'work'") == true)
}

// MARK: - Palette command run reporting

/// Runs one palette command the way `SessionStore` does, from a temporary
/// environment.
///
/// `SHELL` deliberately points at a stub: `AppProcessEnvironment` caches its
/// shell dump per shell path, and `ShellEnvironmentLoadingTests` asserts against
/// the `/bin/zsh` entry, so a background command sharing that key would race
/// with it (and would otherwise read the developer's login files).
private func runPaletteTestCommand(
    _ shellCommand: String
) throws -> (outcome: PaletteCommandOutcome, logURL: URL) {
    let stub = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-palette-test-shell-\(UUID().uuidString)")
    try "#!/bin/sh\nexit 0\n".write(to: stub, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    defer { try? FileManager.default.removeItem(at: stub) }

    let logURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-palette-bg-\(UUID().uuidString).log")

    let outcome = SessionStore.runPaletteBackgroundCommand(
        shellCommand: shellCommand,
        cwd: "/tmp",
        homeDirectory: NSHomeDirectory(),
        environment: [
            "SHELL": stub.path,
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
            "TERM": "dumb"
        ],
        parentSessionID: nil,
        logURL: logURL
    )
    return (outcome, logURL)
}

@Test func paletteBackgroundCommandCapturesBothStreamsAndTheExitStatus() throws {
    let (outcome, logURL) = try runPaletteTestCommand("echo to-stdout; echo to-stderr 1>&2; exit 3")
    defer { try? FileManager.default.removeItem(at: logURL) }

    guard case .finished(let exitCode, let output) = outcome else {
        Issue.record("expected a finished run, got \(outcome)")
        return
    }
    #expect(exitCode == 3)
    // Both streams used to be discarded (stdout) or kept only for a failure
    // (stderr); the log is what makes "it did nothing" explainable.
    #expect(output.text.contains("to-stdout"))
    #expect(output.text.contains("to-stderr"))
    #expect(FileManager.default.fileExists(atPath: logURL.path))
}

@Test func paletteBackgroundCommandReportsASuccessfulRun() throws {
    let (outcome, logURL) = try runPaletteTestCommand("echo all-good")
    defer { try? FileManager.default.removeItem(at: logURL) }

    guard case .finished(let exitCode, let output) = outcome else {
        Issue.record("expected a finished run, got \(outcome)")
        return
    }
    #expect(exitCode == 0)
    #expect(output.text.contains("all-good"))
}

/// A `run: background` command's only explanation is its output, so the tail
/// has to survive whatever the command printed.
@Test func paletteRunLogTailKeepsTheLastLinesAndFlagsTruncation() {
    let output = PaletteCommandRunLog.truncating(
        (1...10).map { "line \($0)" }.joined(separator: "\n"),
        maxBytes: 4096,
        maxLines: 3
    )

    #expect(output.text == "line 8\nline 9\nline 10")
    #expect(output.isTruncated)
}

@Test func paletteRunLogTailDropsAPartialLeadingLine() {
    let output = PaletteCommandRunLog.truncating(
        "aaaaaaaaaa\nbbbbbbbbbb\ncccccccccc",
        maxBytes: 15,
        maxLines: 10
    )

    // The byte cap cuts into `bbbb…`, so the tail starts at the first whole line.
    #expect(output.text == "cccccccccc")
    #expect(output.isTruncated)
}

@Test func paletteRunLogTailDropsABrokenMultibyteCharacter() {
    let text = "ok\n" + String(repeating: "é", count: 200)
    let output = PaletteCommandRunLog.truncating(text, maxBytes: 21, maxLines: 60)

    // 21 bytes lands mid-`é`, so the tail is the whole characters that remain.
    #expect(!output.text.unicodeScalars.contains("\u{FFFD}"))
    #expect(output.text == String(repeating: "é", count: 10))
    #expect(output.isTruncated)
}

@Test func paletteRunLogTailIsUnchangedWhenItFits() {
    let output = PaletteCommandRunLog.truncating("review-linear: done", maxBytes: 4096, maxLines: 60)

    #expect(output.text == "review-linear: done")
    #expect(!output.isTruncated)
}

@Test func paletteRunLogReadsTheEndOfAFile() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-palette-run-\(UUID().uuidString).log")
    defer { try? FileManager.default.removeItem(at: url) }
    try (1...20).map { "line \($0)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

    let output = PaletteCommandRunLog.tail(of: url, maxBytes: 4096, maxLines: 2)

    #expect(output.text == "line 19\nline 20")
    #expect(output.isTruncated)
    // A run whose log was never written still has an exit status to report.
    #expect(PaletteCommandRunLog.tail(of: url.appendingPathExtension("missing")) == .empty)
}

@Test func paletteRunLogFileNameIsTimestampedAndSanitized() {
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let name = PaletteCommandRunLog.fileName(commandID: "review issue/ENG-123", startedAt: startedAt)

    #expect(name.hasSuffix("-review-issue-ENG-123"))
    #expect(!name.contains("/"))
    #expect(!name.contains(" "))
}

@Test func paletteRunLogFileURLAvoidsCollisionsWithinTheSameSecond() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-palette-run-dir-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)

    let first = PaletteCommandRunLog.fileURL(in: directory, commandID: "review", startedAt: startedAt)
    #expect(first.lastPathComponent.hasSuffix("-review.log"))

    try Data().write(to: first)
    let second = PaletteCommandRunLog.fileURL(in: directory, commandID: "review", startedAt: startedAt)
    #expect(second.lastPathComponent.hasSuffix("-review-2.log"))
    #expect(second != first)
}

@Test func paletteCommandRunHeadlinesAndFailureDetailCoverEveryStatus() {
    let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
    func run(_ status: PaletteCommandRun.Status, outputTail: String = "") -> PaletteCommandRun {
        PaletteCommandRun(
            commandID: "review",
            title: "Review ENG-123",
            command: "~/bin/review-linear ENG-123",
            startedAt: startedAt,
            status: status,
            outputTail: outputTail
        )
    }

    let running = run(.running)
    #expect(running.headline == "Running Review ENG-123…")
    #expect(running.isRunning)
    #expect(!running.isFailure)

    let succeeded = run(.succeeded)
    #expect(succeeded.headline == "Review ENG-123 finished")
    #expect(!succeeded.isFailure)

    let failed = run(.failed(exitCode: 1), outputTail: "review-linear: agent-run not found\n")
    #expect(failed.headline == "Review ENG-123 failed (exit 1)")
    #expect(failed.isFailure)
    #expect(failed.failureDetail == "review-linear: agent-run not found")

    let couldNotStart = run(.couldNotStart, outputTail: "Unable to start custom command")
    #expect(couldNotStart.headline == "Review ENG-123 could not start")
    #expect(couldNotStart.isFailure)

    let launched = run(.launchedSession(id: "ENG-123"))
    #expect(launched.headline == "Review ENG-123 → session ENG-123")
    #expect(!launched.isFailure)
    // No output at all is not a failure detail; the banner shows the headline only.
    #expect(run(.failed(exitCode: 2)).failureDetail == nil)
}
