import BanyanCore
import Foundation

let banyanTestHost = HostRuntimeContext(
    environment: ProcessInfo.processInfo.environment,
    homeDirectory: URL(fileURLWithPath: NSHomeDirectory()),
    currentDirectory: FileManager.default.currentDirectoryPath
)

let banyanTestTelemetry = PerformanceTelemetry(
    store: PerformanceEventStore(
        databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("banyan-tests-telemetry.sqlite")
    )
)

let banyanTestTmuxBackend = TmuxBackend(
    environment: banyanTestHost.environment,
    workingDirectory: banyanTestHost.currentDirectory,
    // A socket of its own. A store built on this backend runs the same launch
    // reap the app does, and on the app's socket that reap sees every live
    // session, matches none of the fixture's rows, and kills the lot.
    socketName: "banyan-test"
)

extension TmuxBackend {
    /// Ends a fixture's private tmux server and, with it, every pane it hosts.
    /// Killing only the fixture's sessions, or never reaching cleanup because
    /// setup threw, leaves the server and its fake agents running for days.
    func killPrivateTestServer() {
        // Never the app's live server, nor the socket other tests share.
        guard socketName != TmuxBackend.socketName, socketName != banyanTestTmuxBackend.socketName else { return }
        _ = try? SubprocessRunner.run(
            arguments: [executableURL.path, "-L", socketName, "kill-server"],
            cwd: "/", environment: ["PATH": "/usr/bin:/bin"], timeout: 10
        )
    }
}

/// SIGKILLs this user's processes whose command line names `root`, a
/// fixture-unique temporary directory. Pane processes can sit in their own
/// process groups and fixture helpers may ignore SIGHUP, so a dead tmux server
/// does not guarantee they exit. A flat listing, not a walk down from launchd:
/// right after the server dies its orphans still name an exited parent.
func killFixtureProcesses(namingPath root: URL) {
    guard let output = try? SubprocessRunner.run(
        arguments: ["/bin/ps", "-axww", "-o", "pid=,uid=,args="],
        cwd: "/", environment: ["PATH": "/usr/bin:/bin"], timeout: 10
    ) else { return }
    for line in String(decoding: output.standardOutput, as: UTF8.self).split(separator: "\n")
    where line.contains(root.path) {
        let fields = line.split(separator: " ", maxSplits: 2)
        guard fields.count == 3, let pid = Int32(fields[0]), pid != getpid(),
              UInt32(fields[1]) == getuid() else { continue }
        _ = kill(pid, SIGKILL)
    }
}
