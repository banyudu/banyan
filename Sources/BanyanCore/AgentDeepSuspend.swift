import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct AgentDiskSession: Codable, Equatable, Sendable {
    public let provider: CodingAgentProvider
    public let id: String
    public let cwd: String

    public init(provider: CodingAgentProvider, id: String, cwd: String) {
        self.provider = provider
        self.id = id
        self.cwd = cwd
    }
}

/// A tmux journal survives frontend crashes. It records recovery before TERM,
/// and binds it to both the kernel pane identity and the exact pane ID.
public struct AgentSuspendTicket: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case terminating, suspended, resuming }
    public let root: AgentProcessIdentity
    public let shell: AgentProcessIdentity
    public let agent: AgentProcessIdentity
    public let paneID: String
    public let disk: AgentDiskSession
    public let resumeCommand: String
    public let residentBytes: UInt64
    public var phase: Phase
    public let survivors: [AgentProcessIdentity]
    public let idleTranscriptPath: String?

    public init(root: AgentProcessIdentity, shell: AgentProcessIdentity, agent: AgentProcessIdentity,
                paneID: String, disk: AgentDiskSession, resumeCommand: String, residentBytes: UInt64,
                phase: Phase = .terminating, survivors: [AgentProcessIdentity] = [], idleTranscriptPath: String? = nil) {
        self.root = root; self.shell = shell; self.agent = agent; self.paneID = paneID
        self.disk = disk; self.resumeCommand = resumeCommand; self.residentBytes = residentBytes
        self.phase = phase; self.survivors = survivors
        self.idleTranscriptPath = idleTranscriptPath
    }
}

public struct AgentDeepSuspendPolicy: Codable, Equatable, Sendable {
    public var automatic: Bool
    public var idleMinutes: Double

    public init(automatic: Bool = false, idleMinutes: Double = 45) {
        self.automatic = automatic
        self.idleMinutes = idleMinutes
    }

    public var idleSeconds: TimeInterval {
        min(24 * 60, max(1, idleMinutes.isFinite ? idleMinutes : 45)) * 60
    }

    /// Pressure escalates only after a full quiet minute, never during a turn.
    public func threshold(underPressure: Bool) -> TimeInterval {
        underPressure ? min(60, idleSeconds) : idleSeconds
    }
}

public struct AgentSuspendCandidate: Sendable {
    public let id: String
    public let lastInteraction: Date
    public let eligible: Bool
    public init(id: String, lastInteraction: Date, eligible: Bool) {
        self.id = id; self.lastInteraction = lastInteraction; self.eligible = eligible
    }
}

public enum AgentDeepSuspend {
    /// Require a current input affordance near the bottom of the live screen.
    /// Old provider banners in scrollback and a shell echo are not readiness.
    public static func hasReadyPrompt(provider: CodingAgentProvider, text: String) -> Bool {
        let tail = text.split(separator: "\n").suffix(8).map { $0.trimmingCharacters(in: .whitespaces) }
        if provider == .opencode {
            return tail.contains { $0.lowercased().contains("ask anything") || $0.lowercased().contains("tab agents") }
        }
        return tail.contains { line in
            ["❯", "›", "❱", ">"].contains(line)
                || line.hasPrefix("❯ ") || line.hasPrefix("› ") || line.hasPrefix("❱ ")
        }
    }
    /// Idle classification concerns the foreground provider and its children.
    /// A pre-existing shell-owned background server is not an active agent turn.
    public static func foregroundTable(rows: [ProcessInfoRow], agentPID: Int) -> ProcessTable {
        let table = ProcessTable(rows: rows)
        var pids = Set(table.descendants(of: agentPID).map(\.pid))
        var parent = rows.first { $0.pid == agentPID }?.parentPID
        while let pid = parent, pids.insert(pid).inserted {
            parent = rows.first { $0.pid == pid }?.parentPID
        }
        return ProcessTable(rows: rows.filter { pids.contains($0.pid) })
    }
    public static func launchArguments(_ command: String) -> (words: [String], environment: [String])? {
        guard var words = AgentSessionHistory.literalArguments(command), !words.isEmpty else { return nil }
        if words.first == "exec" { words.removeFirst() }
        var environment: [String] = []
        if words.first == "env" {
            words.removeFirst()
            // Only explicit owned launch settings are supported. Arbitrary
            // env/wrapper programs keep the one-shot launch behavior.
            guard words.first == "OPENCODE_DISABLE_AUTOUPDATE=true" else { return nil }
            environment = ["env", words.removeFirst()]
        }
        return (words, environment)
    }
    public static func leastRecentlyUsed(_ candidates: [AgentSuspendCandidate]) -> [String] {
        candidates.filter(\.eligible).sorted {
            $0.lastInteraction == $1.lastInteraction ? $0.id < $1.id : $0.lastInteraction < $1.lastInteraction
        }.map(\.id)
    }

    public static func validID(_ id: String, provider: CodingAgentProvider) -> Bool {
        if provider == .claude || provider == .codex { return UUID(uuidString: id) != nil }
        if provider == .opencode {
            return id.hasPrefix("ses_") && id.count > 4 && id.count < 160
                && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
        }
        return false
    }

    /// Never choose "newest in cwd". Explicit IDs must also exist in the
    /// provider's disk store at this cwd; an open transcript proves process
    /// ownership when no ID was passed at launch.
    public static func resolve(provider: CodingAgentProvider, command: String, cwd: String,
                               candidates: [AgentResumeCandidate], openTranscripts: [URL],
                               requireHeldTranscript: Bool = true) throws -> AgentDiskSession {
        guard [.claude, .codex, .opencode].contains(provider),
              let invocation = launchArguments(command) else {
            throw AgentFreezeError.unsafe("Unsupported or non-literal provider launch")
        }
        let words = invocation.words
        guard let first = words.first, (first as NSString).lastPathComponent == provider.defaultExecutableName else {
            throw AgentFreezeError.unsafe("Provider executable does not match the launch")
        }
        let canonicalCWD = PathDisplayName.canonicalPath(cwd)
        let matching = candidates.filter { $0.provider == provider
            && PathDisplayName.canonicalPath($0.cwd) == canonicalCWD && validID($0.sourceID, provider: provider) }
        let flags: Set<String> = provider == .claude ? ["--session-id", "--resume", "-r"]
            : provider == .opencode ? ["--session", "-s"] : []
        var explicit: Set<String> = []
        for (index, word) in words.enumerated() {
            if flags.contains(word), index + 1 < words.count { explicit.insert(words[index + 1]) }
            for flag in flags where word.hasPrefix(flag + "=") { explicit.insert(String(word.dropFirst(flag.count + 1))) }
        }
        if provider == .codex, let index = words.firstIndex(of: "resume") {
            explicit.formUnion(words.dropFirst(index + 1).filter { validID($0, provider: provider) })
        }
        var held: Set<String> = []
        for url in Set(openTranscripts) where url.pathExtension == "jsonl" {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 262_144) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n") {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                let metadata = provider == .codex && object["type"] as? String == "session_meta"
                    ? object["payload"] as? [String: Any] : provider == .claude || provider == .opencode ? object : nil
                guard let metadata, let diskCWD = metadata["cwd"] as? String,
                      PathDisplayName.canonicalPath(diskCWD) == canonicalCWD,
                      let id = metadata[provider == .claude ? "sessionId" : "id"] as? String,
                      validID(id, provider: provider) else { continue }
                held.insert(id)
            }
        }
        let ids = explicit.isEmpty ? held : explicit
        guard ids.count == 1, let id = ids.first,
              matching.contains(where: { $0.sourceID == id }), held.isEmpty || held == ids,
              !requireHeldTranscript || held == ids else {
            throw AgentFreezeError.unsafe("Exact provider session identity is unresolved or ambiguous; agent left running")
        }
        return AgentDiskSession(provider: provider, id: id, cwd: cwd)
    }

    /// Validate the actual new provider argv, not merely a provider-looking PID
    /// in the pane. JSONL providers must have opened the intended transcript:
    /// argv and a stale prompt alone do not prove startup completed.
    public static func confirmsRecovery(_ disk: AgentDiskSession, process: ProcessInfoRow) -> Bool {
        guard let command = providerCommand(provider: disk.provider, process: process) else { return false }
        if let identity = AgentProcessSample.read(pid: Int32(process.pid))?.identity {
            do {
                if let current = try AgentProviderIdentity.query(process: identity, provider: disk.provider, cwd: disk.cwd) {
                    return current == disk
                }
            } catch { return false }
        }
        let candidate = AgentResumeCandidate(provider: disk.provider, sourceID: disk.id, cwd: disk.cwd,
            createdAt: .distantPast, updatedAt: Date())
        guard let open = try? openTranscripts(pid: Int32(process.pid)),
              let resolved = try? resolve(provider: disk.provider, command: command, cwd: disk.cwd,
                  candidates: [candidate], openTranscripts: open,
                  requireHeldTranscript: true) else { return false }
        return resolved == disk
    }

    public static func providerCommand(provider: CodingAgentProvider, process: ProcessInfoRow) -> String? {
        guard process.isSupportedAgentForFreezing, let argv = process.argumentVector,
              let index = argv.firstIndex(where: { ($0 as NSString).lastPathComponent == provider.defaultExecutableName }) else { return nil }
        return argv.dropFirst(index).map(AgentLaunchCommand.shellQuote).joined(separator: " ")
    }

    public static func openTranscripts(pid: Int32) throws -> [URL] {
        let result = try SubprocessRunner.run(arguments: ["/usr/sbin/lsof", "-a", "-p", String(pid), "-Fn"],
            cwd: "/", environment: ProcessInfo.processInfo.environment, timeout: 4)
        guard result.terminationStatus == 0 else {
            throw AgentFreezeError.unsafe("Could not inspect the provider's open transcript files")
        }
        return String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("n/") && $0.hasSuffix(".jsonl") }
            .map { URL(fileURLWithPath: String($0.dropFirst())) }
    }

    /// Codex can wait quietly on the network while the frontend status is stale.
    /// Reuse handoff's bounded, fail-closed completed-turn protocol on the exact
    /// held rollout; terminal text and near-zero CPU cannot replace it.
    public static func codexIdleTranscript(_ disk: AgentDiskSession, open: [URL]) throws -> String {
        let matching = Set(open.filter { (try? codexTranscriptCWD($0, disk: disk)) != nil })
        guard matching.count == 1, let url = matching.first else {
            throw AgentFreezeError.unsafe("Exact held Codex rollout is unavailable or ambiguous")
        }
        try validateCodexIdleTranscript(url.path, disk: disk)
        return url.path
    }

    public static func validateCodexIdleTranscript(_ path: String, disk: AgentDiskSession) throws {
        let url = URL(fileURLWithPath: path)
        try CodexTUIHandoff.validateCompletedTranscript(url, threadID: disk.id, cwd: codexTranscriptCWD(url, disk: disk))
    }

    private static func codexTranscriptCWD(_ url: URL, disk: AgentDiskSession) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let header = try file.read(upToCount: 65_536) ?? Data()
        guard let first = header.split(separator: 10).first,
              let row = try JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
              row["type"] as? String == "session_meta", let meta = row["payload"] as? [String: Any],
              meta["id"] as? String == disk.id, let cwd = meta["cwd"] as? String,
              PathDisplayName.canonicalPath(cwd) == PathDisplayName.canonicalPath(disk.cwd) else {
            throw AgentFreezeError.unsafe("Codex rollout identity does not match the live session")
        }
        return cwd
    }

    public static func resumeCommand(disk: AgentDiskSession, launchCommand: String, host: String, shell: String) throws -> String {
        guard let resume = AgentSessionHistory.resumeCommand(provider: disk.provider, sourceID: disk.id, cwd: disk.cwd),
              let invocation = launchArguments(launchCommand),
              let launchExecutable = invocation.words.first,
              (launchExecutable as NSString).lastPathComponent == disk.provider.defaultExecutableName,
              let resumeWords = AgentSessionHistory.literalArguments(resume) else {
            throw AgentFreezeError.unsafe("Could not construct exact provider resume command")
        }
        var words = invocation.words
        let executable = words.removeFirst()
        // Retain launch settings (profile/model/permissions/config), drop only
        // the initial prompt and existing identity flags. Reject subcommands,
        // remote attachments and fork modes whose ownership is not local.
        let takesValue: Set<String>
        let switches: Set<String>
        let identityFlags: Set<String>
        let variadicOptions: Set<String>
        switch disk.provider {
        case .codex:
            takesValue = ["-p", "--profile", "-c", "--config", "-m", "--model", "-s", "--sandbox", "-a", "--ask-for-approval",
                "--add-dir", "--enable", "--disable"]
            switches = ["--no-daemon", "--dangerously-bypass-approvals-and-sandbox", "--full-auto", "--no-alt-screen", "--search"]
            identityFlags = ["-C", "--cd"]
            variadicOptions = ["--add-dir"]
        case .claude:
            takesValue = ["--model", "--permission-mode", "--effort", "--settings", "--mcp-config", "--add-dir",
                "--append-system-prompt", "--system-prompt", "--allowedTools", "--disallowedTools", "--tools", "--plugin-dir"]
            switches = ["--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--strict-mcp-config"]
            identityFlags = ["--resume", "-r", "--session-id"]
            variadicOptions = ["--allowedTools", "--disallowedTools", "--tools", "--add-dir", "--plugin-dir"]
        case .opencode:
            takesValue = ["-m", "--model", "--agent"]
            switches = ["--pure", "--auto", "--mini"]
            identityFlags = ["--session", "-s"]
            variadicOptions = []
        default:
            throw AgentFreezeError.unsafe("Provider has no safe resume option schema")
        }
        var options: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            if disk.provider == .codex, word == "resume" { index += 1; continue }
            if identityFlags.contains(word) {
                if disk.provider == .claude, ["--resume", "-r"].contains(word) {
                    // Claude's selector argument is optional. Never consume the
                    // following permission/model option when no selector exists.
                    index += index + 1 < words.count && !words[index + 1].hasPrefix("-") ? 2 : 1
                } else {
                    guard index + 1 < words.count, !words[index + 1].hasPrefix("-") else {
                        throw AgentFreezeError.unsafe("Missing provider identity/cwd option value")
                    }
                    index += 2
                }
                continue
            }
            if validID(word, provider: disk.provider) { index += 1; continue }
            if takesValue.contains(word) {
                guard index + 1 < words.count else { throw AgentFreezeError.unsafe("Missing launch option value") }
                if variadicOptions.contains(word), index + 2 < words.count, !words[index + 2].hasPrefix("-") {
                    throw AgentFreezeError.unsafe("Ambiguous variadic permission/launch option; use an inline value before deep suspension")
                }
                options += [word, words[index + 1]]; index += 2; continue
            }
            if switches.contains(word) { options.append(word); index += 1; continue }
            if word.hasPrefix("-"), let flag = word.split(separator: "=", maxSplits: 1).first,
               takesValue.contains(String(flag)) || identityFlags.contains(String(flag)) {
                if takesValue.contains(String(flag)) { options.append(word) }
                index += 1; continue
            }
            // One positional argument is the initial prompt. Anything else is
            // not a launch shape we can reproduce without changing semantics.
            guard index == words.count - 1, !word.hasPrefix("-"),
                  !["exec", "run", "attach", "serve", "web", "app-server", "--fork"].contains(word) else {
                throw AgentFreezeError.unsafe("Launch options cannot be safely preserved on resume")
            }
            index += 1
        }
        let command = (invocation.environment + [executable] + options + resumeWords.dropFirst()).map(AgentLaunchCommand.shellQuote).joined(separator: " ")
        return [host, AgentProcessHost.subcommand, AgentProcessHost.inheritedFlag, shell, command]
            .map(AgentLaunchCommand.shellQuote).joined(separator: " ")
    }

    /// The only destructive operation in deep suspend. Never signal a group or
    /// a child. Full-tree ownership/identity checks are shared with tier one.
    public static func terminateAgent(_ ticket: AgentSuspendTicket, freezePlan: AgentFreezeTicket) throws {
        let fresh = try AgentProcessFreezer.plan(root: ticket.root, agentPIDs: [ticket.agent.pid],
            samples: AgentProcessFreezer.snapshot(rootPID: ticket.root.pid))
        guard Set(fresh.members) == Set(freezePlan.members), fresh.groups == freezePlan.groups,
              fresh.agents == [ticket.agent], let agent = AgentProcessSample.read(pid: ticket.agent.pid),
              agent.identity == ticket.agent, !agent.isStopped, agent.userID == getuid(),
              ticket.agent.pid > 1, ticket.agent.pid != getpid(), ticket.agent.pid != ticket.root.pid else {
            throw AgentFreezeError.unsafe("Agent identity changed or agent-only TERM failed")
        }
        if ticket.disk.provider == .codex {
            guard let path = ticket.idleTranscriptPath else { throw AgentFreezeError.unsafe("Codex completed-turn evidence is missing") }
            try validateCodexIdleTranscript(path, disk: ticket.disk)
        }
        guard kill(ticket.agent.pid, SIGTERM) == 0 else { throw AgentFreezeError.unsafe("Agent-only TERM failed") }
    }
}
