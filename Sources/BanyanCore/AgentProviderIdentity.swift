import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// On-demand provider state, never a cached launch ID or a last-written session.
/// Files are private to one kernel pane lifetime. A fresh nonce and the live
/// provider PID bind every answer; a missing/disabled adapter fails closed.
public enum AgentProviderIdentity {
    public static let helper = "__provider-identity"
    private static let lock = NSLock()

    public static func directory(root: AgentProcessIdentity) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "banyan-provider-\(getuid())-\(root.pid)-\(root.startSeconds)-\(root.startMicroseconds)")
    }

    private static func privateDirectory(_ directory: URL) -> Bool {
        var info = stat()
        return lstat(directory.path, &info) == 0 && info.st_uid == getuid()
            && info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) && info.st_mode & 0o077 == 0
    }

    /// Called only by the inherited host of an explicitly literal provider.
    /// Do not edit user settings or override an existing custom TUI config.
    public static func prepare(command: String, executable: String) throws -> String {
        guard let invocation = AgentDeepSuspend.launchArguments(command),
              let first = invocation.words.first,
              let provider = [CodingAgentProvider.claude, .opencode].first(where: { $0.defaultExecutableName == (first as NSString).lastPathComponent }),
              let root = AgentProcessSample.read(pid: getsid(0))?.identity else { return command }
        let dir = directory(root: root)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        guard privateDirectory(dir) else { throw AgentFreezeError.unsafe("Provider identity bridge directory is not private") }
        // Probe before adding options/config: an older provider must retain its
        // normal launch. Keep the private marker so identity queries fail closed
        // instead of silently falling back when this adapter is unsupported.
        let version = try? SubprocessRunner.run(arguments: [first, "--version"],
            cwd: FileManager.default.currentDirectoryPath,
            environment: ProcessInfo.processInfo.environment, timeout: 2)
        guard let version, version.terminationStatus == 0,
              supportsAdapter(provider: provider, version: String(decoding: version.standardOutput, as: UTF8.self)) else { return command }
        let quote = AgentLaunchCommand.shellQuote
        if provider == .claude {
            let plugin = dir.appendingPathComponent("claude")
            try FileManager.default.createDirectory(at: plugin.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: plugin.appendingPathComponent("hooks"), withIntermediateDirectories: true)
            try Data(#"{"name":"banyan-session-identity","version":"1.0.0","description":"Private on-demand current-session identity for Banyan"}"#.utf8)
                .write(to: plugin.appendingPathComponent(".claude-plugin/plugin.json"), options: .atomic)
            try Data(#"{"modules":["./identity.mjs"]}"#.utf8).write(to: plugin.appendingPathComponent("hooks/hooks.json"), options: .atomic)
            try Data(claudeSource.utf8).write(to: plugin.appendingPathComponent("hooks/identity.mjs"), options: .atomic)
            // Append the variadic option after the prompt so it cannot swallow it.
            setenv("BANYAN_AGENT_IDENTITY_DIR", dir.path, 1)
            setenv("BANYAN_AGENT_IDENTITY_HOST", executable, 1)
            return (invocation.environment + invocation.words + ["--plugin-dir", plugin.path]).map(quote).joined(separator: " ")
        }
        // The explicit config is an additional layer in OpenCode 1.18.34;
        // global/project plugins and TUI settings continue to merge normally.
        guard ProcessInfo.processInfo.environment["OPENCODE_TUI_CONFIG"] == nil else {
            // Keep the user's command/config untouched; probes time out safely.
            return command
        }
        let plugin = dir.appendingPathComponent("opencode.mjs")
        try Data(openCodeSource.utf8).write(to: plugin, options: .atomic)
        let config = dir.appendingPathComponent("tui.json")
        try JSONSerialization.data(withJSONObject: ["plugin": [plugin.path]]).write(to: config, options: .atomic)
        setenv("BANYAN_AGENT_IDENTITY_DIR", dir.path, 1)
        setenv("BANYAN_AGENT_IDENTITY_HOST", executable, 1)
        setenv("OPENCODE_TUI_CONFIG", config.path, 1)
        return command
    }

    public static func supportsAdapter(provider: CodingAgentProvider, version: String) -> Bool {
        guard let token = version.split(whereSeparator: \.isWhitespace).first else { return false }
        let parts = token.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        if provider == .claude { return parts[0] == 2 && (parts[1] > 1 || parts[1] == 1 && parts[2] >= 277) }
        if provider == .opencode { return parts[0] == 1 && (parts[1] > 18 || parts[1] == 18 && parts[2] >= 34) }
        return false
    }

    public static func cleanup(root: AgentProcessIdentity) {
        let dir = directory(root: root)
        if privateDirectory(dir) { try? FileManager.default.removeItem(at: dir) }
    }

    /// Only the native wait helper launched directly by this Claude process.
    /// Names alone cannot exempt an arbitrary child from activity/identity checks.
    public static func ownedWaitHelpers(samples: [AgentProcessSample], rows: [ProcessInfoRow],
                                        process: AgentProcessIdentity, root: AgentProcessIdentity,
                                        executable: String) -> Set<AgentProcessIdentity> {
        guard let owner = samples.first(where: { $0.identity == process }), owner.sessionID == root.pid else { return [] }
        let directory = directory(root: root).path
        return Set(samples.compactMap { sample in
            guard sample.parentPID == process.pid, sample.sessionID == root.pid, sample.userID == owner.userID,
                  let row = rows.first(where: { $0.pid == Int(sample.identity.pid) }), let argv = row.argumentVector,
                  argv.count == 5, PathDisplayName.canonicalPath(row.commandName) == PathDisplayName.canonicalPath(executable),
                  PathDisplayName.canonicalPath(argv[0]) == PathDisplayName.canonicalPath(executable),
                  argv[1] == helper, argv[2] == "wait", argv[3] == directory,
                  argv[4].isEmpty || UUID(uuidString: argv[4]) != nil,
                  AgentProcessSample.read(pid: sample.identity.pid)?.identity == sample.identity else { return nil }
            return sample.identity
        })
    }

    /// Helper invoked by Claude's supported process API once, at plugin load.
    /// Walk kernel ancestry rather than trusting a PID from provider JSON.
    public static func owningProviderPID() throws -> Int32 {
        var pid = getppid()
        let table = ProcessTable.snapshot()
        for _ in 0..<8 {
            guard let row = table.descendants(of: Int(pid)).first(where: { $0.pid == Int(pid) }),
                  let sample = AgentProcessSample.read(pid: pid), sample.userID == getuid() else { break }
            if row.isSupportedAgentForFreezing, AgentDeepSuspend.providerCommand(provider: .claude, process: row) != nil { return pid }
            pid = sample.parentPID
        }
        throw AgentFreezeError.unsafe("Identity helper is not owned by a Claude process")
    }

    /// A dormant owned child, called through Claude's supported process API.
    /// Directory and parent-exit notifications wake it; the one-shot deadline
    /// refreshes the API call before its ten-minute subprocess limit.
    public static func waitForRequest(directory dir: URL, excluding nonce: String) throws -> String? {
        #if canImport(Darwin)
        let pid = try owningProviderPID()
        guard let sample = AgentProcessSample.read(pid: pid),
              let root = AgentProcessSample.read(pid: sample.sessionID)?.identity,
              dir.standardizedFileURL == directory(root: root).standardizedFileURL, privateDirectory(dir) else {
            throw AgentFreezeError.unsafe("Identity helper directory does not belong to its pane")
        }
        let descriptor = open(dir.path, O_EVTONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw AgentFreezeError.unsafe("Could not watch identity requests") }
        let wake = DispatchSemaphore(value: 0)
        let files = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename], queue: .global())
        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        files.setEventHandler { wake.signal() }; exit.setEventHandler { wake.signal() }
        files.setCancelHandler { close(descriptor) }
        files.resume(); exit.resume()
        defer { files.cancel(); exit.cancel() }
        let deadline = DispatchTime.now() + .seconds(540)
        while AgentProcessSample.presence(of: sample.identity) != .exited {
            if let data = try? Data(contentsOf: dir.appendingPathComponent("request.json")),
               let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let next = request["nonce"] as? String, UUID(uuidString: next) != nil,
               next != nonce, (request["pid"] as? NSNumber)?.int32Value == pid,
               request["provider"] as? String == "claude" { return String(decoding: data, as: UTF8.self) }
            if wake.wait(timeout: deadline) == .timedOut { return nil }
        }
        throw AgentFreezeError.unsafe("Provider exited")
        #else
        throw AgentFreezeError.unsafe("Provider identity watcher requires macOS")
        #endif
    }

    public struct Answer: Codable, Equatable, Sendable {
        public let nonce: String
        public let pid: Int32
        public let provider: CodingAgentProvider
        public let id: String
        public let cwd: String
        public let ready: Bool
    }

    public static func validate(_ answer: Answer, nonce: String, process: AgentProcessIdentity,
                                provider: CodingAgentProvider, cwd: String) throws -> AgentDiskSession {
        guard answer.nonce == nonce, answer.pid == process.pid, answer.provider == provider, answer.ready,
              AgentDeepSuspend.validID(answer.id, provider: provider),
              PathDisplayName.canonicalPath(answer.cwd) == PathDisplayName.canonicalPath(cwd),
              AgentProcessSample.read(pid: process.pid)?.identity == process else {
            throw AgentFreezeError.unsafe("Current provider session/idle state is unconfirmed")
        }
        return .init(provider: provider, id: answer.id, cwd: cwd)
    }

    /// Nil means this pane predates the adapter. An installed but unavailable
    /// adapter throws, so older held-file evidence cannot hide its failure.
    public static func query(process: AgentProcessIdentity, provider: CodingAgentProvider, cwd: String) throws -> AgentDiskSession? {
        guard [.claude, .opencode].contains(provider),
              let sample = AgentProcessSample.read(pid: process.pid), sample.identity == process,
              let root = AgentProcessSample.read(pid: sample.sessionID)?.identity else { return nil }
        let dir = directory(root: root)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        guard privateDirectory(dir) else { throw AgentFreezeError.unsafe("Provider identity bridge is unavailable") }
        lock.lock()
        defer { lock.unlock() }
        let nonce = UUID().uuidString
        let request = dir.appendingPathComponent("request.json")
        let reply = dir.appendingPathComponent("\(nonce).json")
        defer { try? FileManager.default.removeItem(at: request); try? FileManager.default.removeItem(at: reply) }
        try JSONSerialization.data(withJSONObject: ["nonce": nonce, "pid": process.pid, "provider": provider.rawValue])
            .write(to: request, options: .atomic)
        // Bounded file RPC only during suspend/startup verification. The
        // provider adapter sleeps on filesystem events between requests.
        let end = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < end {
            if let data = try? Data(contentsOf: reply), let answer = try? JSONDecoder().decode(Answer.self, from: data) {
                let disk = try validate(answer, nonce: nonce, process: process, provider: provider, cwd: cwd)
                // Claude renews its dormant helper after answering. Let that
                // owned child settle before the caller samples the process tree.
                if provider == .claude { Thread.sleep(forTimeInterval: 0.1) }
                return disk
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw AgentFreezeError.unsafe("Provider current-session adapter did not answer; keep running. Check plugin support/enabling and custom TUI config.")
    }

    public static let claudeSource = #"""
    // Claude Code mods API: $.session.id()/cwd() are live engine getters.
    // Query only on demand, including when the JSONL is closed between writes.
    export function register(on) {
      let readID, readCWD, agents, writeReply, runHelper, serving, generation = 0;
      const active = new Set();
      on("turn.start", ($, e, next) => { active.add(e.turnId); return next(e) });
      on("turn.complete", ($, e, next) => { active.delete(e.turnId); return next(e) });
      on("session.start", async ($, e, next) => {
        // The mods sandbox permits API calls, but forbids storing/passing $.
        // Refresh these call closures while keeping one process-serving loop.
        readID = () => $.session.id();
        readCWD = () => $.session.cwd();
        agents = () => $.agent.list();
        writeReply = (path, text) => $.fs.write(path, text);
        runHelper = argv => $.process.run(argv, { timeoutMs: 600000 });
        generation++;
        if (serving) return next(e);
        // Claim the loop before awaiting configuration: overlapping starts
        // must not each launch a helper while the first is still initializing.
        serving = true;
        let dir, host;
        try {
          dir = await $.env.get("BANYAN_AGENT_IDENTITY_DIR");
          host = await $.env.get("BANYAN_AGENT_IDENTITY_HOST");
        } catch { serving = false; return next(e) }
        if (!dir || !host) { serving = false; return next(e) }
        const serve = async () => {
          let last = "";
          for (;;) try {
            const result = await runHelper([host, "__provider-identity", "wait", dir, last]);
            if (result.exitCode === 75) continue;
            if (result.exitCode !== 0) return;
            const request = JSON.parse(result.stdout);
            if (request.provider !== "claude" || !/^[0-9a-f-]{36}$/i.test(request.nonce)) return;
            last = request.nonce;
            const pid = request.pid;
            const current = generation;
            const id = await readID(), cwd = await readCWD();
            const running = (await agents()).some(agent => agent.status === "running");
            // Re-read identity after the async calls; a switch never publishes
            // a mixed old/new answer. Failure yields no reusable evidence.
            if (current !== generation || id !== await readID() || cwd !== await readCWD()) continue;
            await writeReply(dir + "/" + request.nonce + ".json", JSON.stringify({
              nonce: request.nonce, pid, provider: "claude", id, cwd, ready: active.size === 0 && !running
            }));
          } catch { return }
        };
        void serve().finally(() => { serving = false });
        return next(e);
      });
    }
    """#

    public static let openCodeSource = #"""
    import { watch, readFileSync, writeFileSync } from "node:fs";
    // OpenCode 1.18.34 TUI plugin contract. Server idle events alone do not
    // identify the selected TUI conversation; read its live route on demand.
    export default { id: "banyan.session-identity", async tui(api) {
      const dir = process.env.BANYAN_AGENT_IDENTITY_DIR;
      if (!dir) return;
      let inFlight = false, pending = false, disposed = false, last = "";
      const answer = async () => {
        if (disposed) return;
        if (inFlight) { pending = true; return }
        inFlight = true;
        try {
          const request = JSON.parse(readFileSync(dir + "/request.json", "utf8"));
          if (request.pid !== process.pid || request.provider !== "opencode"
            || !/^[0-9a-f-]{36}$/i.test(request.nonce) || request.nonce === last) return;
          last = request.nonce;
          const route = api.route.current;
          if (!api.state.ready || route.name !== "session") return;
          const id = route.params.sessionID, info = api.state.session.get(id);
          if (!info || info.id !== id) return;
          const statuses = await api.client.session.status();
          if (disposed || statuses.error || !statuses.data || api.route.current.name !== "session" || api.route.current.params.sessionID !== id) return;
          const ready = api.mode.current() === "base" && !api.ui.dialog.open
            && Object.values(statuses.data).every(s => s.type === "idle")
            && !api.state.session.permission(id).length && !api.state.session.question(id).length;
          writeFileSync(dir + "/" + request.nonce + ".json", JSON.stringify({
            nonce: request.nonce, pid: process.pid, provider: "opencode", id, cwd: info.directory, ready
          }), { mode: 0o600 });
        } catch {} finally {
          inFlight = false;
          // Coalesce events received during the status RPC into one re-read.
          // Even a refused/stale answer must hand back a newer request.
          if (pending && !disposed) { pending = false; void answer() }
        }
      };
      // macOS/Bun may coalesce atomic renames or omit the changed filename.
      // Re-read the nonce on every directory event, including an answer write.
      const watcher = watch(dir, () => { void answer() });
      // One event-loop handback also covers a request published while the
      // watcher is arming. Subsequent work is driven only by directory events.
      const startup = setImmediate(() => { void answer() });
      api.lifecycle.onDispose(() => { disposed = true; clearImmediate(startup); watcher.close() });
      void answer();
    }};
    """#
}
