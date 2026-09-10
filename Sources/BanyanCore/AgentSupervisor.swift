import Foundation

public protocol AgentSupervisorBackend: TmuxSessionBackend {}

public struct AgentSupervisor: Sendable {
    public struct Result: Sendable {
        public let status: SessionStatus
        public let tone: SessionTone
        public let provider: CodingAgentProvider?
        public let modelID: String?
        public let modelIDIsExact: Bool
        public let currentPath: String?

        public init(
            status: SessionStatus,
            tone: SessionTone,
            provider: CodingAgentProvider?,
            modelID: String? = nil,
            modelIDIsExact: Bool = false,
            currentPath: String?
        ) {
            self.status = status
            self.tone = tone
            self.provider = provider
            self.modelID = modelID
            self.modelIDIsExact = modelIDIsExact
            self.currentPath = currentPath
        }
    }

    private let backend: any AgentSupervisorBackend
    private let processTable: ProcessTable

    public init(
        backend: any AgentSupervisorBackend,
        processTable: ProcessTable
    ) {
        self.backend = backend
        self.processTable = processTable
    }

    public func inspect(
        tmuxSessionName: String,
        launchCommand: String,
        currentStatus: SessionStatus,
        cwd: String = "",
        sessionStartedAt: Date = .distantPast,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Result? {
        inspect(
            tmuxSessionName: tmuxSessionName,
            launchCommand: launchCommand,
            currentStatus: currentStatus,
            cwd: cwd,
            sessionStartedAt: sessionStartedAt,
            environment: environment,
            paneSnapshot: backend.primaryPaneSnapshot(named: tmuxSessionName)
        )
    }

    /// Inspects a session using pane metadata fetched by a batch lookup. Keeping
    /// the pane snapshot separate avoids one `tmux list-panes` subprocess per
    /// session during a supervisor tick.
    public func inspect(
        tmuxSessionName: String,
        launchCommand: String,
        currentStatus: SessionStatus,
        cwd: String = "",
        sessionStartedAt: Date = .distantPast,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        paneSnapshot: TmuxPaneSnapshot?
    ) -> Result? {
        guard currentStatus != .closed else { return nil }
        guard let pane = paneSnapshot else {
            return backend.hasSession(named: tmuxSessionName)
                ? nil
                : Result(status: .closed, tone: .neutral, provider: nil, currentPath: nil)
        }
        guard !pane.isDead else {
            return Result(status: .closed, tone: .neutral, provider: nil, currentPath: pane.currentPath)
        }

        let descendants = processTable.descendants(of: pane.rootPID)
        // Only treat this as an agent session when an agent process is actually
        // alive in the pane. A launch command like `banyan-worktree --claude …`
        // names the agent forever, so keying provider detection off it pinned a
        // session to its agent long after the agent exited and the pane dropped
        // back to a bare shell — leaving a stale provider icon and idle-agent
        // affordances. A running claude/codex always lives as a child process of
        // the pane's login shell (claude even renames itself to its version, so
        // the pane's own command is an unreliable signal), so the descendant
        // process tree is the truth for liveness. `launchCommand` is still used to
        // *name* the provider once a live agent is present.
        let baseProvider = Self.hasLiveAgentProcess(paneCommand: pane.currentCommand, descendants: descendants)
            ? Self.detectProvider(
                launchCommand: launchCommand,
                paneCommand: pane.currentCommand,
                descendants: descendants
            )
            : nil

        guard let baseProvider else {
            return Result(status: .running, tone: .blue, provider: nil, currentPath: pane.currentPath)
        }

        let hasLiveOpenCode = Self.hasLiveOpenCodeProcess(paneCommand: pane.currentCommand, descendants: descendants)
        var modelIdentity: OpenCodeRuntimeIdentity? = if hasLiveOpenCode {
            OpenCodeSessionModelDetector().resolve(
                directory: pane.currentPath.isEmpty ? cwd : pane.currentPath,
                sessionStartedAt: sessionStartedAt,
                environment: environment
            )
        } else {
            nil
        }
        var provider = modelIdentity?.provider ?? baseProvider

        // tmux reports the foreground command separately from the process
        // table. When the pane is backed by a login shell, both can describe
        // the same agent (for example `pane_current_command == opencode` and
        // an `opencode` child of the shell). Do not count that representation
        // twice, but do count the pane's agent when a different agent appears
        // below it.
        let rootAgentProvider = CodingAgentProvider.detect(in: pane.currentCommand)
        let rootAgentProcessCount = if let rootAgentProvider,
                                        !descendants.contains(where: { $0.supportedAgentProvider == rootAgentProvider }) {
            1
        } else {
            0
        }
        let agentProcessCount = Self.logicalAgentProcessCount(in: descendants)
        if rootAgentProcessCount + agentProcessCount > 1 {
            if modelIdentity == nil, hasLiveOpenCode {
                let visibleText = backend.captureVisibleText(paneID: pane.paneID, lineLimit: 60)
                modelIdentity = OpenCodeSessionModelDetector.statusBarIdentity(in: visibleText)
                provider = modelIdentity?.provider ?? baseProvider
            }
            return result(.subagents, .purple)
        }

        let helperPIDs = Self.agentHelperPIDs(in: descendants)
        let externalProcesses = descendants.filter { process in
            process.pid != pane.rootPID
                && !process.isExited
                && !process.isSupportedAgent
                && !process.isShellOrWrapper
                && !process.isTmuxPlumbing
                && !process.isBanyanAgentLogProcess
                && !process.isCodexRuntimeHelper
                && !helperPIDs.contains(process.pid)
        }

        if !externalProcesses.isEmpty {
            return result(.executing, .blue)
        }

        let visibleText = backend.captureVisibleText(paneID: pane.paneID, lineLimit: 60)
        if modelIdentity == nil, hasLiveOpenCode {
            modelIdentity = OpenCodeSessionModelDetector.statusBarIdentity(in: visibleText)
            provider = modelIdentity?.provider ?? baseProvider
        }
        // A live turn is checked first: its interrupt affordance is scoped to the
        // visible tail, so it beats an untouched-looking prompt during the moment
        // a slash command is still running.
        if Self.looksLikeAgentExecuting(visibleText) {
            return result(.executing, .blue)
        }
        // An untouched prompt outranks the question scan, which searches the whole
        // captured window and therefore also sees scrollback from *before* a
        // `/clear`. A cleared session whose old conversation happened to contain a
        // phrase like "should I merge…" would otherwise stay pinned to `.asking`
        // forever; nothing below the banner can be a live question.
        if Self.looksLikeUntouchedAgentPrompt(visibleText) {
            return result(.idle, .neutral)
        }
        if Self.looksLikeAgentQuestion(visibleText) {
            return result(.asking, .yellow)
        }

        return result(.needInput, .yellow)

        func result(_ status: SessionStatus, _ tone: SessionTone) -> Result {
            Result(
                status: status,
                tone: tone,
                provider: provider,
                modelID: modelIdentity?.modelID,
                modelIDIsExact: modelIdentity?.isExactModelID ?? false,
                currentPath: pane.currentPath
            )
        }
    }

    public static func isSupportedAgentCommand(_ command: String) -> Bool {
        CodingAgentProvider.isSupportedCommand(command)
    }

    /// True when an agent process is actually running in the pane — either the
    /// pane's foreground command is a known agent, or a supported agent binary
    /// appears anywhere in the descendant process tree. This is what separates a
    /// live agent session from one whose agent has exited back to a bare shell.
    static func hasLiveAgentProcess(paneCommand: String, descendants: [ProcessInfoRow]) -> Bool {
        isSupportedAgentCommand(paneCommand) || descendants.contains(where: \.isSupportedAgent)
    }

    static func hasLiveOpenCodeProcess(paneCommand: String, descendants: [ProcessInfoRow]) -> Bool {
        CodingAgentProvider.detect(in: paneCommand) == .opencode
            || descendants.contains { $0.supportedAgentProvider == .opencode }
    }

    static func detectProvider(
        launchCommand: String,
        paneCommand: String,
        descendants: [ProcessInfoRow]
    ) -> CodingAgentProvider? {
        if let provider = CodingAgentProvider.detect(in: launchCommand) {
            return provider
        }
        if let provider = CodingAgentProvider.detect(in: paneCommand) {
            return provider
        }
        return descendants.compactMap(\.supportedAgentProvider).first
    }

    /// PIDs of the persistent MCP-server helpers a coding agent spawns and keeps
    /// alive across turns, plus any workers they fork. An MCP server is launched
    /// as a direct child of the agent process at startup and lives for the whole
    /// session, so — unlike a genuine command execution — it must not pin the
    /// session to `.executing` and hide idle-only affordances like the handoff
    /// button. We match them by name rather than by "any non-shell child" so a
    /// real foreground command the agent runs directly is still seen as work.
    static func agentHelperPIDs(in descendants: [ProcessInfoRow]) -> Set<Int> {
        let agentPIDs = Set(descendants.filter(\.isSupportedAgent).map(\.pid))
        guard !agentPIDs.isEmpty else { return [] }

        var helperPIDs = Set(
            descendants
                .filter { process in
                    agentPIDs.contains(process.parentPID) && process.isLikelyMCPServer
                }
                .map(\.pid)
        )
        guard !helperPIDs.isEmpty else { return [] }

        // Fold in any workers a helper forks (e.g. a node MCP server spawning a
        // child), so the whole persistent subtree is treated as idle plumbing.
        let childrenByParent = Dictionary(grouping: descendants, by: \.parentPID)
        var queue = Array(helperPIDs)
        while let pid = queue.popLast() {
            for child in childrenByParent[pid] ?? [] where !helperPIDs.contains(child.pid) {
                helperPIDs.insert(child.pid)
                queue.append(child.pid)
            }
        }
        return helperPIDs
    }

    static func logicalAgentProcessCount(in descendants: [ProcessInfoRow]) -> Int {
        // A login shell can contain the launched agent in its arguments (for
        // example `/bin/zsh -lc claude`) while the real Claude process is its
        // child. Keep shell arguments available for liveness/provider
        // detection, but never count the shell itself as a second agent.
        let agentProcesses = descendants.filter { process in
            process.isSupportedAgent && !process.isShellOrWrapper
        }
        let agentProcessesByParent = Dictionary(grouping: agentProcesses, by: \.parentPID)

        return agentProcesses.filter { process in
            guard process.isNodeAgentLauncher else { return true }
            guard let provider = process.supportedAgentProvider else { return true }
            let childAgents = agentProcessesByParent[process.pid] ?? []
            return !childAgents.contains { $0.supportedAgentProvider == provider }
        }.count
    }

    private static func looksLikeAgentQuestion(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let questionPhrases = [
            "do you want",
            "would you like",
            "should i",
            "can i",
            "shall i",
            "approve",
            "approval required",
            "permission required",
            "allow this",
            "continue?"
        ]
        if questionPhrases.contains(where: lowercased.contains) {
            return true
        }

        let trimmedLines = lowercased
            .split(separator: "\n")
            .suffix(8)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return trimmedLines.contains { line in
            line.hasSuffix("?") && line.count >= 8
        }
    }

    /// True when the pane shows an agent sitting at a prompt it has never been
    /// asked to do anything with — freshly launched, or reset with `/clear`.
    ///
    /// Such a session is idle but carries no result to look at, so it must not be
    /// reported as `.needInput` alongside sessions that actually finished a turn;
    /// a rarely-used empty session would otherwise wave for attention forever.
    ///
    /// The signal is structural rather than a banner match alone: every agent
    /// prints its welcome box at startup and re-prints it on `/clear`, but the box
    /// also lingers in the captured scrollback for the first few turns afterwards.
    /// So we locate the banner, then require that *nothing but chrome* appears
    /// between the end of that box and the input row — no agent output, no echoed
    /// prompt other than a slash command like the `/clear` that produced this
    /// state. Anything unrecognized counts as content, keeping `.needInput` the
    /// conservative default: a missed idle marker is cosmetic, a missed result is
    /// not.
    static func looksLikeUntouchedAgentPrompt(_ text: String) -> Bool {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        if looksLikeUntouchedOpenCodePrompt(lines) {
            return true
        }

        // Banner titles: Claude renders `╭─── Claude Code v2.x ───╮`, Codex
        // `│ >_ OpenAI Codex (v0.x) │`.
        let bannerMarkers = ["claude code v", "openai codex (v", "welcome to claude code"]
        guard let bannerIndex = lines.lastIndex(where: { line in
            let lowercased = line.lowercased()
            return bannerMarkers.contains(where: lowercased.contains)
        }) else {
            return false
        }

        // Skip the rest of the header. Claude renders either a full welcome box
        // (body rows and a closing border) or, in a plain launch, a compact block
        // whose logo rows carry the model and cwd text alongside the art — so the
        // skip has to cover box borders and logo glyphs alike.
        var start = bannerIndex + 1
        while start < lines.count, isBannerChrome(lines[start]) {
            start += 1
        }

        // The input row is the last prompt marker in the capture; everything below
        // it is the status footer, which never reflects conversation content.
        let end = lines[start...].lastIndex(where: isPromptRow) ?? lines.count
        guard start <= end else { return false }

        // A turn nobody asked for leaves output behind without leaving a result to
        // read. Its transcript is only discounted when the region carries a marker
        // naming it as machine-triggered *and* the user typed nothing themselves —
        // an echoed human prompt always counts as work, so a session that did real
        // work before a heartbeat fired still asks for attention.
        let region = lines[start..<end]
        let isBackgroundOnly = region.contains { line in
            let lowercased = line.lowercased()
            return Self.backgroundActivityMarkers.contains(where: lowercased.contains)
        }

        return region.allSatisfy { isIdlePromptChrome($0, discountingAgentOutput: isBackgroundOnly) }
    }

    /// OpenCode has no textual startup banner. Its empty input instead renders
    /// the `Ask anything...` placeholder beneath the logo, with only logo and
    /// input-frame chrome in between. The placeholder disappears as soon as a
    /// user begins a turn, so this distinguishes a fresh or `/clear`-ed session
    /// from OpenCode's used-but-idle footer, which must remain `.needInput`.
    private static func looksLikeUntouchedOpenCodePrompt(_ lines: [String]) -> Bool {
        guard let placeholderIndex = lines.lastIndex(where: {
            $0.lowercased().contains("ask anything...")
        }) else {
            return false
        }
        guard let logoIndex = lines[..<placeholderIndex].lastIndex(where: isOpenCodeLogoRow) else {
            return false
        }

        return lines[logoIndex..<placeholderIndex].allSatisfy { line in
            line.isEmpty || isBannerChrome(line)
        }
    }

    private static func isOpenCodeLogoRow(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return bannerArtCharacters.contains(first) && line.contains("█")
    }

    /// Marks a turn as self-triggered rather than requested by the user. Kept
    /// narrow on purpose: a `/loop` doing real work must still raise attention, so
    /// this matches the heartbeat's own sentinel rather than the generic wakeup
    /// banner every loop prints. Add a marker here to silence another automation.
    private static let backgroundActivityMarkers = ["__cache-warm-ping__"]

    /// Leading glyphs of the agent's own transcript rows (bullets, tool results,
    /// spinner summaries) — content, unless the turn that produced them was a
    /// background heartbeat.
    private static let agentOutputMarkers = Set("⏺⎿✻✳⧗↳•·")

    private static let boxDrawingCharacters = Set("─│╭╮╰╯┌┐└┘├┤┬┴┼━┄┈╌═↯┃╹")

    private static func isDividerOnly(_ line: String) -> Bool {
        !line.isEmpty && line.allSatisfy { boxDrawingCharacters.contains($0) || $0 == " " }
    }

    /// Glyphs the agent logos are drawn from, which lead every row of Claude's
    /// compact startup header.
    private static let bannerArtCharacters = Set("▐▛▜▝▘▟▙▖▗▚▞▀▄▌█")

    private static func isBannerChrome(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return boxDrawingCharacters.contains(first) || bannerArtCharacters.contains(first)
    }

    private static func isPromptRow(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return first == "❯" || first == "›" || first == "❱"
    }

    /// Lines that can sit between the welcome box and the input row without
    /// meaning the agent did any work.
    private static func isIdlePromptChrome(_ line: String, discountingAgentOutput: Bool = false) -> Bool {
        if line.isEmpty || isDividerOnly(line) {
            return true
        }
        if line.lowercased().hasPrefix("tip:") {
            return true
        }
        if discountingAgentOutput, let first = line.first, agentOutputMarkers.contains(first) {
            return true
        }
        // An echoed slash command — `❯ /clear`, `❯ /new` — is the very action that
        // emptied the session, not work left behind in it.
        if isPromptRow(line) {
            let typed = line.dropFirst().trimmingCharacters(in: .whitespaces)
            return typed.isEmpty || typed.hasPrefix("/")
        }
        return false
    }

    /// True only when the visible tail shows the agent is *actively* working —
    /// not merely that its finished output happens to mention work. Matching bare
    /// words like `working`/`editing`/`running` pinned idle sessions to
    /// `.executing` forever, because an agent's completion summary is full of them
    /// (e.g. Codex prints `Worked for 3m 38s` and bullets like `Ran … before
    /// editing.` while sitting at an idle prompt). TUI agents instead render a
    /// live "interrupt" affordance only while a turn is in flight and drop it the
    /// instant they return to the prompt, so that hint is the reliable signal.
    private static func looksLikeAgentExecuting(_ text: String) -> Bool {
        let lines = text
            .lowercased()
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let tail = lines.suffix(8)

        // Claude no longer prints an interrupt hint at all, so the live elapsed
        // counter is the only in-band signal that a turn is still running. It sits
        // above the prompt box and the (user-configurable, multi-line) status
        // footer, so it needs more headroom than the hint scans below.
        if lines.suffix(14).contains(where: looksLikeLiveProgressCounter) {
            return true
        }

        // A live interrupt affordance is shown only while a turn is running
        // (Claude: "esc to interrupt", Codex: "Esc to interrupt", OpenCode:
        // "esc interrupt" without the "to", etc.). Matching the bare hint as
        // well as the "to" form keeps OpenCode sessions from falling through to
        // `.needInput` while a turn is still in flight.
        let interruptHints = [
            "esc to interrupt",
            "esc interrupt",
            "esc to stop",
            "esc stop",
            "ctrl-c to interrupt",
            "ctrl-c interrupt",
            "ctrl+c to interrupt",
            "ctrl+c interrupt"
        ]
        if tail.contains(where: { line in interruptHints.contains(where: line.contains) }) {
            return true
        }

        // Fallback for agents without an interrupt hint: a work verb on a line
        // that is still animating (trailing ellipsis). A past-tense summary line
        // such as "Worked for 3m 38s" or "Ran git diff --check." ends in a period,
        // not an ellipsis, so it deliberately does not match.
        let progressVerbs = [
            "thinking", "working", "running", "executing",
            "reading", "editing", "searching", "generating"
        ]
        return tail.contains { line in
            guard line.hasSuffix("…") || line.hasSuffix("...") else { return false }
            return progressVerbs.contains(where: line.contains)
        }
    }

    /// True for a spinner line whose trailing parenthetical is a *live* counter,
    /// e.g. Claude's `✳ Whirlpooling… (5m 55s · ↓ 21.2k tokens)`. The gerund is
    /// randomized per turn and the line does not end in the ellipsis, so neither
    /// the verb list nor a trailing-ellipsis test can see it.
    ///
    /// Three conditions together keep finished output from matching: the line ends
    /// in `)`, the ellipsis appears *before* that group (so an elided tool call
    /// like `bash(… sleep 30s)` does not qualify), and the group carries an
    /// elapsed-seconds token — which `(1m context)` in a status footer and
    /// `(ctrl+o to expand)` under a collapsed result both lack.
    static func looksLikeLiveProgressCounter(_ line: String) -> Bool {
        guard line.hasSuffix(")"), let open = line.lastIndex(of: "(") else { return false }
        let head = line[line.startIndex..<open]
        guard head.contains("…") || head.contains("...") else { return false }
        return containsElapsedSeconds(line[line.index(after: open)..<line.index(before: line.endIndex)])
    }

    /// True when the text carries a duration token whose unit is seconds (`12s`,
    /// the `55s` of `5m 55s`). Requiring the seconds unit — rather than any
    /// `<number><unit>` pair — is what keeps `Opus 5 (1M context)` out.
    private static func containsElapsedSeconds(_ text: Substring) -> Bool {
        let characters = Array(text)
        for index in characters.indices where characters[index] == "s" {
            guard index > 0, characters[index - 1].isNumber else { continue }
            let next = index + 1
            guard next == characters.count || !characters[next].isLetter && !characters[next].isNumber else {
                continue
            }
            return true
        }
        return false
    }
}

public protocol ProcessTableProvider: Sendable {
    func snapshot() -> ProcessTable
}

public struct LiveProcessTableProvider: Sendable, ProcessTableProvider {
    public init() {}

    public func snapshot() -> ProcessTable {
        ProcessTable.snapshot()
    }
}

public struct ProcessTable: Sendable {
    private let childrenByParent: [Int: [ProcessTableRow]]
    private let rowByPID: [Int: ProcessTableRow]

    public init(rows: [ProcessInfoRow]) {
        self.init(tableRows: rows.map(\.tableRow))
    }

    init(tableRows rows: [ProcessTableRow]) {
        self.childrenByParent = Dictionary(grouping: rows, by: \.parentPID)
        // The process table is external input; never crash on a duplicate pid row.
        self.rowByPID = Dictionary(rows.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public static func snapshot() -> ProcessTable {
        ProcessTable(tableRows: ProcessTableSource.rows())
    }

    /// The process subtree rooted at `rootPID`, classified.
    ///
    /// Reading argv and deciding what a process *is* both cost real work — a
    /// syscall and a scan of the command line — and a tick only ever asks about
    /// the few dozen processes below a pane, so both are deferred to here rather
    /// than paid for all ~900 processes on the machine when the snapshot is taken.
    public func descendants(of rootPID: Int) -> [ProcessInfoRow] {
        var rows: [ProcessTableRow] = rowByPID[rootPID].map { [$0] } ?? []
        var queue = childrenByParent[rootPID] ?? []
        var visited = Set(rows.map(\.pid))

        while let process = queue.popLast() {
            guard !visited.contains(process.pid) else { continue }
            visited.insert(process.pid)
            rows.append(process)
            queue.append(contentsOf: childrenByParent[process.pid] ?? [])
        }

        let commandLines = ProcessTableSource.commandLines(
            forPIDs: rows.filter { $0.resolvedCommand == nil }.map(\.pid)
        )
        return rows.map { row in
            ProcessInfoRow(row: row, command: row.resolvedCommand ?? commandLines[row.pid])
        }
    }
}

public struct ProcessInfoRow: Sendable {
    public let pid: Int
    public let parentPID: Int
    public let state: String
    public let elapsed: TimeInterval
    public let commandName: String
    public let arguments: String

    let supportedAgentProvider: CodingAgentProvider?
    let isExited: Bool
    let isSupportedAgent: Bool
    let isShellOrWrapper: Bool
    let isBanyanAgentLogProcess: Bool
    let isCodexRuntimeHelper: Bool
    let isTmuxPlumbing: Bool
    let isNodeAgentLauncher: Bool
    let isLikelyMCPServer: Bool

    public init(
        pid: Int,
        parentPID: Int,
        state: String,
        elapsed: TimeInterval,
        commandName: String,
        arguments: String
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.state = state
        self.elapsed = elapsed
        self.commandName = commandName
        self.arguments = arguments

        let executable = ExecutablePath.lowercasedName(commandName)
        let scan = CommandLineScan(commandName: commandName, arguments: arguments)

        // A process that has exited but not been reaped keeps its name in the
        // process table. It is neither a live agent nor work in flight, so every
        // question below has to answer "no" for it.
        let isExited = state.hasPrefix("Z")
        self.isExited = isExited

        let isBanyanAgentWrapper = executable == "banyan-agent-wrapper"
            || scan.contains(Self.banyanAgentWrapperMarker)

        let isCodexRuntimeHelper = scan.contains(anyOf: Self.codexRuntimeHelperMarkers)
        self.isCodexRuntimeHelper = isCodexRuntimeHelper

        let provider = CodingAgentProvider.detect(in: commandName)
            ?? CodingAgentProvider.detect(in: arguments)
            ?? CodingAgentProvider.detectInPathSegments(of: arguments)
        self.supportedAgentProvider = provider
        self.isSupportedAgent = !isBanyanAgentWrapper && !isCodexRuntimeHelper && !isExited && provider != nil

        self.isShellOrWrapper = Self.shellNames.contains(executable)

        self.isBanyanAgentLogProcess = executable == "tee" && arguments.contains("banyan-agent-process.log")
        self.isTmuxPlumbing = executable == "tmux" || executable == "reattach-to-user-namespace"
        self.isNodeAgentLauncher = executable == "node"

        self.isLikelyMCPServer = scan.contains(anyOf: Self.mcpServerMarkers)
            || scan.hasPrefix(Self.mcpPrefixMarker)
    }

    init(row: ProcessTableRow, command: ProcessCommandLine?) {
        self.init(
            pid: row.pid,
            parentPID: row.parentPID,
            state: row.state,
            elapsed: row.elapsed,
            // A process whose argv the kernel will not hand over — a zombie, or
            // one owned by another user — still gets its accounting name so the
            // subtree walk keeps a stable identity for it.
            commandName: command?.name ?? row.accountingName,
            arguments: command?.arguments ?? row.accountingName
        )
    }

    var tableRow: ProcessTableRow {
        ProcessTableRow(
            pid: pid,
            parentPID: parentPID,
            state: state,
            elapsed: elapsed,
            accountingName: commandName,
            resolvedCommand: ProcessCommandLine(name: commandName, arguments: arguments)
        )
    }

    private static let shellNames: Set<String> = [
        "bash", "zsh", "sh", "fish", "login", "env", "script", "banyan-agent-wrapper"
    ]

    private static let banyanAgentWrapperMarker = CommandLineMarker("banyan-agent-wrapper")

    private static let codexRuntimeHelperMarkers = [
        CommandLineMarker("codex-code-mode-host"),
        CommandLineMarker("cua_node")
    ]

    private static let mcpServerMarkers = [
        CommandLineMarker("modelcontextprotocol"),
        CommandLineMarker("mcp-server"),
        CommandLineMarker("mcp_server"),
        CommandLineMarker("-mcp"),
        CommandLineMarker("/mcp"),
        CommandLineMarker(" mcp")
    ]

    private static let mcpPrefixMarker = CommandLineMarker("mcp")

    public static func load() -> [ProcessInfoRow] {
        ProcessTable(tableRows: ProcessTableSource.rows()).allRows()
    }
}

extension ProcessTable {
    /// Every row, classified. Only used by callers that genuinely need the whole
    /// machine; a supervisor tick wants `descendants(of:)`.
    func allRows() -> [ProcessInfoRow] {
        let rows = rowByPID.values.sorted { $0.pid < $1.pid }
        let commandLines = ProcessTableSource.commandLines(
            forPIDs: rows.filter { $0.resolvedCommand == nil }.map(\.pid)
        )
        return rows.map { row in
            ProcessInfoRow(row: row, command: row.resolvedCommand ?? commandLines[row.pid])
        }
    }
}
