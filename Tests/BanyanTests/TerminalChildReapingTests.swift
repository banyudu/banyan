import Darwin
import Dispatch
import Foundation
import SwiftTerm
import Testing

/// Regression tests for the terminal-client child leak.
///
/// `LocalProcess` used to reap its child only from the `.exit` dispatch source
/// that every teardown path cancelled, so reaping was a side effect of still
/// wanting the exit notification. `terminate()` sent `SIGTERM` and cancelled
/// the monitor in the same breath, which stranded one zombie per attach/detach
/// cycle; a live app was observed with 81 of them against 22 live clients.
///
/// Every test here asserts on the pid itself rather than on a global zombie
/// count, so a child spawned by some other suite cannot make them flap.
@Suite(.serialized)
struct TerminalChildReapingTests {
    /// A child that is gone almost as soon as it is forked — `tmux
    /// attach-session` against a session that no longer exists returns in
    /// milliseconds — races the arming of the exit monitor. Whichever side
    /// wins, it has to be collected, so this runs the race many times.
    ///
    /// The `LocalProcess` objects are deliberately kept alive: this covers the
    /// monitor race on its own, with no help from the teardown paths below.
    /// One child at a time, so another suite scanning for zombie children of
    /// this process sees at most one, for milliseconds.
    @Test func reapsChildrenThatExitBeforeTheMonitorArms() async throws {
        var owners: [LocalProcess] = []
        for _ in 0..<24 {
            let (process, pid) = try startChild(executable: "/usr/bin/true")
            owners.append(process)
            let state = await waitForCollection(of: pid)
            #expect(state == .collected, "pid \(pid) is \(state)")
        }
        withExtendedLifetime(owners) {}
    }

    /// Tearing the client down while its child is alive is the detach path that
    /// leaked: `terminate()` signalled the child and then removed the only
    /// thing that could ever have collected it.
    @Test func reapsChildTerminatedWhileStillRunning() async throws {
        let (process, pid) = try startChild(executable: "/bin/cat")
        #expect(childState(pid) != .collected, "child exited before the test could terminate it")

        process.terminate()

        let state = await waitForCollection(of: pid)
        #expect(state == .collected, "pid \(pid) is \(state)")
        withExtendedLifetime(process) {}
    }

    /// Releasing the owner without terminating it must not strand the child
    /// either — `deinit` used to cancel the monitor and walk away.
    @Test func reapsChildWhenOwnerIsReleasedWithoutTerminate() async throws {
        let pid = try startAndReleaseChild(executable: "/bin/cat")

        let state = await waitForCollection(of: pid)
        #expect(state == .collected, "pid \(pid) is \(state)")
    }

    /// A child that ignores `SIGTERM` (and the `SIGHUP` that closing the pty
    /// primary delivers) is only collected if termination escalates to
    /// `SIGKILL`, and it has to happen inside a bounded budget.
    @Test func reapsChildThatIgnoresSIGTERM() async throws {
        let stub = FileManager.default.temporaryDirectory
            .appendingPathComponent("banyan-stubborn-client-\(UUID().uuidString)")
        let ready = stub.appendingPathExtension("ready")
        // The marker matters: until the shell has run its `trap`, `SIGTERM`
        // still has its default disposition and would simply kill the stub,
        // quietly turning this into a duplicate of the test above.
        try "#!/bin/sh\ntrap '' TERM HUP\n: > '\(ready.path)'\nwhile :; do sleep 1; done\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        defer {
            try? FileManager.default.removeItem(at: stub)
            try? FileManager.default.removeItem(at: ready)
        }

        let (process, pid) = try startChild(executable: stub.path)
        try #require(await waitForFile(ready), "stub never installed its signal traps")
        #expect(childState(pid) == .alive, "stub exited before the test could terminate it")

        process.terminate()

        let state = await waitForCollection(of: pid, within: ChildReaperBudget.escalation)
        #expect(state == .collected, "pid \(pid) survived termination and is \(state)")
        withExtendedLifetime(process) {}
    }

    /// The shape the app actually churns through: one terminal view attaching,
    /// detaching and reattaching over and over (`reattachTerminalClient`).
    /// Every cycle used to leave its client behind, and nothing ever swept them.
    @Test func repeatedAttachDetachCyclesLeaveNothingBehind() async throws {
        let delegate = StubDelegate()
        let process = LocalProcess(delegate: delegate, dispatchQueue: DispatchQueue(label: "reap-test.churn"))
        var pids: [pid_t] = []

        for _ in 0..<20 {
            process.startProcess(executable: "/bin/cat", environment: [])
            let pid = process.shellPid
            try #require(pid > 0, "forkpty failed")
            #expect(!pids.contains(pid), "pid \(pid) was reused, so the test proves nothing")
            pids.append(pid)

            process.terminate()
            let state = await waitForCollection(of: pid)
            #expect(state == .collected, "pid \(pid) is \(state)")
        }
        withExtendedLifetime((process, delegate)) {}
    }
}

/// Termination escalates to `SIGKILL` after a two-second grace, so a child
/// that ignores `SIGTERM` is collected a little after that.
private enum ChildReaperBudget {
    static let escalation: TimeInterval = 8
}

// MARK: - Child helpers

private final class StubDelegate: LocalProcessDelegate {
    func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}
    func dataReceived(slice: ArraySlice<UInt8>) {}
    func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    }
}

/// `LocalProcess` holds its delegate weakly, so the caller keeps both alive.
private func startChild(executable: String) throws -> (LocalProcess, pid_t) {
    let delegate = StubDelegate()
    // Never the main queue: a Swift Testing body does not drain it, so delegate
    // callbacks posted there would never run.
    let process = LocalProcess(delegate: delegate, dispatchQueue: DispatchQueue(label: "reap-test.child"))
    process.startProcess(executable: executable, environment: [])
    let pid = process.shellPid
    try #require(pid > 0, "forkpty failed for \(executable)")
    // The delegate is only needed for the window size at fork time.
    withExtendedLifetime(delegate) {}
    return (process, pid)
}

/// Starts a child and lets its owner go out of scope, exercising `deinit`.
private func startAndReleaseChild(executable: String) throws -> pid_t {
    let (process, pid) = try startChild(executable: executable)
    _ = process
    return pid
}

// MARK: - Process-table observation

private enum ChildState: CustomStringConvertible {
    /// Running, so nothing to reap yet.
    case alive
    /// Exited but not waited on: the leak this issue is about.
    case zombie
    /// Reaped — the pid is no longer in the process table.
    case collected

    var description: String {
        switch self {
        case .alive: return "still running"
        case .zombie: return "an unreaped zombie"
        case .collected: return "reaped"
        }
    }
}

private func childState(_ pid: pid_t) -> ChildState {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    // A pid that is gone reports either an error or a zero-length record.
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
        return .collected
    }
    return Int32(info.kp_proc.p_stat) == SZOMB ? .zombie : .alive
}

private func waitForFile(_ url: URL, within seconds: TimeInterval = 10) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !FileManager.default.fileExists(atPath: url.path) {
        guard Date() < deadline else { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

private func waitForCollection(of pid: pid_t, within seconds: TimeInterval = 10) async -> ChildState {
    let deadline = Date().addingTimeInterval(seconds)
    var state = childState(pid)
    while state != .collected, Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
        state = childState(pid)
    }
    return state
}
