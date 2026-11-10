import Foundation
import Testing
@testable import BanyanCore

private let conversationID = "00000000-0000-4000-8000-000000000003"
private let projectCWD = "/tmp/example-project"

private func resumeWords(_ launch: String, provider: CodingAgentProvider = .claude) throws -> [String]? {
    let plan = try AgentResumeCommand.plan(
        provider: provider, sourceID: conversationID, cwd: projectCWD, launchCommand: launch
    )
    return AgentSessionHistory.literalArguments(plan.command)
}

@Test func claudeWrapperResumesThroughTheWrapperItself() throws {
    #expect(try resumeWords("my-claude") == ["my-claude", "--resume", conversationID])
    #expect(try resumeWords("'/Users/example/bin/my-claude'")
        == ["/Users/example/bin/my-claude", "--resume", conversationID])
    #expect(try resumeWords("exec WORK=1 my-claude") == ["WORK=1", "my-claude", "--resume", conversationID])
    // Banyan maps `opus` to Claude, so it is a wrapper rather than another agent.
    #expect(try resumeWords("opus") == ["opus", "--resume", conversationID])
}

@Test func claudeWrapperKeepsKnownOptionsAndReplacesTheEarlierResume() throws {
    // A wrapper recovered once is relaunched as `<wrapper> --resume <id>`; the
    // next recovery must swap that ID rather than append a second one.
    let recovered = "'my-claude' '--model' 'opus' '--resume' '00000000-0000-4000-8000-000000000009'"
    #expect(try resumeWords(recovered) == ["my-claude", "--model", "opus", "--resume", conversationID])
}

@Test func claudeWrapperRefusesAnythingThatIsNotABareWrapper() {
    for launch in [
        // Shells and launchers can run any program; a positional word could be
        // a package, a script or a prompt rather than a Claude option.
        "zsh", "/bin/zsh -l", "bash -c 'claude'", "npx @anthropic-ai/claude-code", "env FOO=1 my-claude",
        "sudo my-claude", "my-claude 'initial prompt'", "my-claude --unknown-flag",
        // Shell syntax and expansion keep their original launch.
        "my-claude && echo done", "my-claude | tee log", "$HOME/bin/my-claude", "~/bin/my-claude",
        "FOO=$BAR my-claude", "my-claude --settings \"$SETTINGS\"",
        // Another provider's executable is not a Claude wrapper.
        "codex", "gemini"
    ] {
        #expect(throws: AgentFreezeError.self, "\(launch)") { try resumeWords(launch) }
    }
}

@Test func wrappersAreOnlyAcceptedForClaude() {
    #expect(throws: AgentFreezeError.self) { try resumeWords("my-codex", provider: .codex) }
    #expect(throws: AgentFreezeError.self) { try resumeWords("my-opencode", provider: .opencode) }
}

@Test func literalClaudeLaunchesStillResumeAsBefore() throws {
    #expect(try resumeWords("'claude' '--model' 'opus' 'initial prompt'")
        == ["claude", "--model", "opus", "--resume", conversationID])
}
