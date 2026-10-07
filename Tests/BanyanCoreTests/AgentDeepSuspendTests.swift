import Foundation
import Testing
@testable import BanyanCore

private let diskID = "00000000-0000-4000-8000-000000000001"
private let otherDiskID = "00000000-0000-4000-8000-000000000002"
private let diskCWD = "/tmp/example-project"

private func candidate(_ id: String, provider: CodingAgentProvider = .codex, cwd: String = diskCWD) -> AgentResumeCandidate {
    .init(provider: provider, sourceID: id, cwd: cwd, createdAt: .distantPast, updatedAt: Date())
}

@Test func deepSuspendExactIdentityRejectsNewestHeuristicWrongCWDAndAmbiguity() throws {
    let candidates = [candidate(diskID), candidate(otherDiskID)]
    let held = FileManager.default.temporaryDirectory.appendingPathComponent("banyan-exact-\(UUID()).jsonl")
    defer { try? FileManager.default.removeItem(at: held) }
    try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": diskID, "cwd": diskCWD]])
        .write(to: held)
    #expect(throws: AgentFreezeError.self) {
        try AgentDeepSuspend.resolve(provider: .codex, command: "codex --no-daemon", cwd: diskCWD,
            candidates: candidates, openTranscripts: [])
    }
    let resolved = try AgentDeepSuspend.resolve(provider: .codex, command: "codex --no-daemon resume \(diskID)", cwd: diskCWD,
        candidates: candidates, openTranscripts: [held])
    #expect(resolved.id == diskID)
    #expect(throws: AgentFreezeError.self) {
        try AgentDeepSuspend.resolve(provider: .codex, command: "codex resume \(diskID)", cwd: "/tmp/different",
            candidates: candidates, openTranscripts: [])
    }
    #expect(throws: AgentFreezeError.self) {
        try AgentDeepSuspend.resolve(provider: .claude, command: "claude --resume \(diskID) --session-id \(otherDiskID)", cwd: diskCWD,
            candidates: [candidate(diskID, provider: .claude), candidate(otherDiskID, provider: .claude)], openTranscripts: [])
    }
}

@Test func deepSuspendOpenTranscriptBindsProcessAndRejectsStaleExplicitID() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("banyan-disk-\(UUID()).jsonl")
    defer { try? FileManager.default.removeItem(at: file) }
    let object: [String: Any] = ["type": "session_meta", "payload": ["id": diskID, "cwd": diskCWD]]
    try JSONSerialization.data(withJSONObject: object).write(to: file)
    let candidates = [candidate(diskID), candidate(otherDiskID)]
    #expect(try AgentDeepSuspend.resolve(provider: .codex, command: "codex --no-daemon", cwd: diskCWD,
        candidates: candidates, openTranscripts: [file]).id == diskID)
    #expect(throws: AgentFreezeError.self) {
        try AgentDeepSuspend.resolve(provider: .codex, command: "codex resume \(otherDiskID)", cwd: diskCWD,
            candidates: candidates, openTranscripts: [file])
    }
    #expect(throws: AgentFreezeError.self) {
        try AgentDeepSuspend.resolve(provider: .codex, command: "codex resume \(diskID)", cwd: diskCWD,
            candidates: candidates, openTranscripts: [], requireHeldTranscript: true)
    }
}

@Test func deepSuspendRecoveryKeepsProviderOptionsAndRejectsUnsafeShapes() throws {
    let disk = AgentDiskSession(provider: .codex, id: diskID, cwd: diskCWD)
    let result = try AgentDeepSuspend.resumeCommand(disk: disk,
        launchCommand: "exec codex --no-daemon -p custom -c 'model=\"example\"' 'initial prompt'", host: "/tmp/banyanctl", shell: "/bin/sh")
    let outer = try #require(AgentSessionHistory.literalArguments(result))
    #expect(outer[0] == "/tmp/banyanctl")
    #expect(outer[2] == AgentProcessHost.inheritedFlag)
    let inner = try #require(AgentSessionHistory.literalArguments(outer[4]))
    #expect(inner == ["codex", "--no-daemon", "-p", "custom", "-c", "model=\"example\"", "resume", "-C", diskCWD, diskID])
    for command in ["codex exec task", "codex --remote unix:///tmp/service", "cd /tmp && codex", "codex --fork", "codex $(echo task)"] {
        #expect(throws: AgentFreezeError.self) {
            try AgentDeepSuspend.resumeCommand(disk: disk, launchCommand: command, host: "/tmp/banyanctl", shell: "/bin/sh")
        }
    }
    #expect(!AgentProcessHost.supportsPersistentShell(command: "export EXAMPLE=1; exec codex"))
    #expect(AgentProcessHost.supportsPersistentShell(command: "exec codex --no-daemon"))
    #expect(AgentProcessHost.supportsPersistentShell(command: "env OPENCODE_DISABLE_AUTOUPDATE=true opencode --session ses_example"))
    #expect(!AgentProcessHost.supportsPersistentShell(command: "env OTHER=1 opencode"))
    #expect(throws: AgentFreezeError.self) {
        try AgentDeepSuspend.resumeCommand(disk: .init(provider: .claude, id: diskID, cwd: diskCWD),
            launchCommand: "claude --disallowedTools Bash Write", host: "/tmp/banyanctl", shell: "/bin/sh")
    }
    let optionalResume = try AgentDeepSuspend.resumeCommand(disk: .init(provider: .claude, id: diskID, cwd: diskCWD),
        launchCommand: "claude --resume --permission-mode plan --model example", host: "/tmp/banyanctl", shell: "/bin/sh")
    let wrapped = try #require(AgentSessionHistory.literalArguments(optionalResume))
    #expect(AgentSessionHistory.literalArguments(wrapped[4]) == ["claude", "--permission-mode", "plan", "--model", "example", "--resume", diskID])
}

@Test func deepSuspendPressurePolicyAndLRUProtectIneligibleSessions() {
    let policy = AgentDeepSuspendPolicy(automatic: true, idleMinutes: 45)
    #expect(policy.threshold(underPressure: true) == 60)
    #expect(policy.threshold(underPressure: false) == 2700)
    #expect(AgentDeepSuspendPolicy(idleMinutes: .nan).idleSeconds == 2700)
    let now = Date()
    #expect(AgentDeepSuspend.leastRecentlyUsed([
        .init(id: "focused", lastInteraction: .distantPast, eligible: false),
        .init(id: "newer", lastInteraction: now, eligible: true),
        .init(id: "older", lastInteraction: now.addingTimeInterval(-100), eligible: true)
    ]) == ["older", "newer"])
    #expect(ControlRoute.resolve(method: "POST", path: "/agent-suspend") == .deepSuspend)
    #expect(ControlRoute.resolve(method: "POST", path: "/agent-resume") == .deepResume)
    #expect(throws: ControlValidationError.self) { try ControlRoute.deepSuspend.validate(.init()) }
}

@Test func deepSuspendCodexSandboxApprovalProfileConfigAndModelSurviveResume() throws {
    let disk = AgentDiskSession(provider: .codex, id: diskID, cwd: diskCWD)
    for policy in ["-s read-only -a untrusted", "--sandbox workspace-write --ask-for-approval on-request", "-s=read-only -a=never"] {
        let original = "codex --no-daemon \(policy) -p custom -c 'permissions.example=\"strict\"' -m example 'initial prompt'"
        let wrapped = try AgentDeepSuspend.resumeCommand(disk: disk, launchCommand: original, host: "/tmp/banyanctl", shell: "/bin/sh")
        let host = try #require(AgentSessionHistory.literalArguments(wrapped))
        let resumed = try #require(AgentSessionHistory.literalArguments(host[4]))
        let launched = try #require(AgentSessionHistory.literalArguments(original))
        #expect(Array(resumed.prefix(launched.count - 1)) == Array(launched.dropLast()))
        #expect(Array(resumed.suffix(4)) == ["resume", "-C", diskCWD, diskID])
    }
    let openCode = AgentDiskSession(provider: .opencode, id: "ses_example", cwd: diskCWD)
    let wrapped = try AgentDeepSuspend.resumeCommand(disk: openCode,
        launchCommand: "env OPENCODE_DISABLE_AUTOUPDATE=true opencode -s ses_example -m provider/model", host: "/tmp/banyanctl", shell: "/bin/sh")
    let host = try #require(AgentSessionHistory.literalArguments(wrapped))
    #expect(AgentSessionHistory.literalArguments(host[4]) == ["env", "OPENCODE_DISABLE_AUTOUPDATE=true", "opencode", "-m", "provider/model", "--session", "ses_example"])
}

@Test func ownedLaunchModesAreExplicitAndCustomCommandsRemainLiteral() throws {
    let ordinary = AgentLaunchCommand.command(provider: .codex)
    #expect(ordinary == "'codex'")
    #expect(AgentLaunchCommand.command(provider: .codex, ownedForSuspension: true).contains("--no-daemon"))
    #expect(AgentLaunchCommand.command(provider: .opencode, ownedForSuspension: true).contains("OPENCODE_DISABLE_AUTOUPDATE=true"))
    let claude = try #require(AgentSessionHistory.literalArguments(AgentLaunchCommand.command(provider: .claude, ownedForSuspension: true)))
    #expect(claude[1] == "--session-id")
    #expect(UUID(uuidString: claude[2]) != nil)
}
