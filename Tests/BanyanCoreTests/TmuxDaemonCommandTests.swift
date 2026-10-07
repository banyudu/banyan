import Foundation
import Testing
@testable import BanyanCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

@Test func tmuxDaemonCommandReturnsAndReapsWhileDetachedChildHoldsPipes() throws {
    // A real fork/setsid reproduces daemon inheritance: the direct child exits,
    // but the detached grandchild keeps BOTH stdout and stderr open for 4s.
    let started = ContinuousClock.now
    let output = try TmuxDaemonCommand.run(
        executable: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["python3", "-c", """
        import os, time
        ready_read, ready_write = os.pipe()
        child = os.fork()
        if child == 0:
            os.setsid()
            os.write(ready_write, b'x')
            time.sleep(4)
            os._exit(0)
        os.read(ready_read, 1)
        print(os.getpid(), child, flush=True)
        os.write(2, b'direct-stderr')
        os._exit(7)
        """], cwd: FileManager.default.currentDirectoryPath,
        environment: ProcessInfo.processInfo.environment, timeout: 6)
    #expect(ContinuousClock.now - started < .seconds(2))
    #expect(output.terminationStatus == 7)
    #expect(output.standardError == Data("direct-stderr".utf8))
    let pids = String(decoding: output.standardOutput, as: UTF8.self)
        .split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }
    #expect(pids.count == 2)
    guard pids.count == 2 else { return }
    // No signal is sent to the detached child; it has a short, bounded lifetime.
    #expect(kill(pids[1], 0) == 0)
    #expect(getsid(pids[1]) == pids[1])
    var status: Int32 = 0
    #expect(waitpid(pids[0], &status, WNOHANG) == -1)
    #expect(errno == ECHILD, "the direct child must already be reaped")
}

@Test func tmuxDaemonCommandExhaustsLargeStdoutAndStderr() throws {
    let output = try TmuxDaemonCommand.run(
        executable: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", "head -c 262144 /dev/zero; printf stdout-tail; head -c 262144 /dev/zero >&2; printf stderr-tail >&2"],
        cwd: FileManager.default.currentDirectoryPath,
        environment: ProcessInfo.processInfo.environment, timeout: 5)
    #expect(output.terminationStatus == 0)
    #expect(output.standardOutput == Data(repeating: 0, count: 262144) + Data("stdout-tail".utf8))
    #expect(output.standardError == Data(repeating: 0, count: 262144) + Data("stderr-tail".utf8))
}

@Test func tmuxDaemonCommandDoesNotFollowNoisyDetachedChildrenAfterExit() throws {
    let started = ContinuousClock.now
    let output = try TmuxDaemonCommand.run(
        executable: URL(fileURLWithPath: "/usr/bin/env"),
        arguments: ["python3", "-c", #"""
        import os, time
        os.write(1, b'direct-stdout\n')
        os.write(2, b'direct-stderr\n')
        ready_read, ready_write = os.pipe()
        # Multiple independent writers keep each pipe under pressure. Their
        # lifetimes are bounded even if the runner regresses and keeps reading.
        for fd in (1, 1, 2, 2):
            if os.fork() == 0:
                os.setsid()
                os.write(ready_write, b'x')
                until = time.monotonic() + 4
                try:
                    while time.monotonic() < until:
                        os.write(fd, b'x' * 65536)
                except BrokenPipeError:
                    pass
                os._exit(0)
        ready = b''
        while len(ready) < 4:
            ready += os.read(ready_read, 4 - len(ready))
        os._exit(0)
        """#], cwd: FileManager.default.currentDirectoryPath,
        environment: ProcessInfo.processInfo.environment, timeout: 6)
    #expect(ContinuousClock.now - started < .seconds(2))
    #expect(output.terminationStatus == 0)
    #expect(output.standardOutput.starts(with: Data("direct-stdout\n".utf8)))
    #expect(output.standardError.starts(with: Data("direct-stderr\n".utf8)))
}

@Test func tmuxDaemonCommandTimeoutKillsAndReapsItsOwnedChild() throws {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("banyan-daemon-timeout-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: marker) }
    let started = ContinuousClock.now
    #expect {
        try TmuxDaemonCommand.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; echo $$ > \"$1\"; exec sleep 30", "fixture", marker.path],
            cwd: FileManager.default.currentDirectoryPath,
            environment: ProcessInfo.processInfo.environment, timeout: 0.3)
    } throws: { error in
        guard let error = error as? SubprocessRunner.RunError, case .timedOut = error else { return false }
        return true
    }
    #expect(ContinuousClock.now - started < .seconds(3))
    let pid = try #require(Int32(String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
    var status: Int32 = 0
    #expect(waitpid(pid, &status, WNOHANG) == -1)
    #expect(errno == ECHILD, "the timed-out child must already be reaped")
}

@Test func tmuxDaemonCommandReportsExecAndWorkingDirectoryFailures() {
    for (executable, cwd) in [("/nonexistent-banyan-command", FileManager.default.currentDirectoryPath),
                              ("/bin/sh", "/nonexistent-banyan-directory")] {
        #expect {
            try TmuxDaemonCommand.run(executable: URL(fileURLWithPath: executable), arguments: [], cwd: cwd,
                                      environment: ProcessInfo.processInfo.environment, timeout: 1)
        } throws: { error in
            guard let error = error as? SubprocessRunner.RunError, case .launchFailed = error else { return false }
            return true
        }
    }
}
