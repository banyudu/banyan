import CTerminalPTY
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Linux Foundation Process detects exit through an inherited socket. A newly
/// started tmux daemon can retain it after the direct client exits, preventing
/// terminationHandler and reaping. Only Linux new-session uses this owned spawn;
/// normal commands and the generic SubprocessRunner keep their existing path.
enum TmuxDaemonCommand {
    static func run(executable: URL, arguments: [String], cwd: String,
                    environment: [String: String], timeout: TimeInterval,
                    tracingExporter: AxiomExporter? = SubprocessRunner.axiomExporter) throws -> SubprocessRunner.Output {
        let command = executable.lastPathComponent == "env" ? arguments.first ?? "env" : executable.path
        let span = tracingExporter?.startSpan("subprocess.run", attributes: [
            "process.executable.name": TelemetryPrivacy.command(command),
        ])
        do {
            // The owned spawn bypasses SubprocessRunner; trace exactly once here
            // without routing execution back through Foundation Process.
            let output = try runOwned(executable: executable, arguments: arguments, cwd: cwd,
                                      environment: environment, timeout: timeout)
            span?.end(attributes: ["process.exit.code": String(output.terminationStatus)],
                      errorType: output.terminationStatus == 0 ? nil : "nonzero_exit")
            return output
        } catch {
            span?.end(errorType: TelemetryPrivacy.errorType(error))
            throw error
        }
    }

    private static func runOwned(executable: URL, arguments: [String], cwd: String,
                                 environment: [String: String], timeout: TimeInterval) throws -> SubprocessRunner.Output {
        let exit = try CommandExit()
        let argv = ([executable.path] + arguments).map { strdup($0) }
        let envp = environment.map { strdup("\($0.key)=\($0.value)") }
        defer { (argv + envp).forEach { free($0) } }
        var stdoutFD: Int32 = -1, stderrFD: Int32 = -1, pid: pid_t = 0
        let error = (argv + [nil]).withUnsafeBufferPointer { args in
            (envp + [nil]).withUnsafeBufferPointer { env in
                banyan_command_spawn(executable.path, args.baseAddress, env.baseAddress, cwd,
                                     &stdoutFD, &stderrFD, &pid)
            }
        }
        guard error == 0 else {
            throw SubprocessRunner.RunError.launchFailed(underlying: POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO))
        }
        defer { close(stdoutFD); close(stderrFD) }
        exit.observe(pid)
        defer { exit.closeWakeup() }
        defer { if exit.status == nil { exit.terminate() } }
        var output = Data(), errors = Data()
        var stdoutOpen = true, stderrOpen = true
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
        while exit.status == nil {
            let now = DispatchTime.now().uptimeNanoseconds
            if now >= deadline {
                throw SubprocessRunner.RunError.timedOut
            }
            var descriptors = [pollfd(fd: stdoutOpen ? stdoutFD : -1, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: stderrOpen ? stderrFD : -1, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: exit.readFD, events: Int16(POLLIN), revents: 0)]
            let remaining = Int32(clamping: (deadline - now + 999_999) / 1_000_000)
            if poll(&descriptors, 3, remaining) < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if exit.status != nil { break }
            // Bound each live read burst so a noisy child cannot starve timeout
            // or stderr handling. The final post-exit drain remains exhaustive.
            try drain(stdoutFD, into: &output, open: &stdoutOpen, byteLimit: 32 * 65536)
            try drain(stderrFD, into: &errors, open: &stderrOpen, byteLimit: 32 * 65536)
        }
        // Direct-child exit guarantees all its bytes are already in the pipes.
        // Snapshot BOTH pipes before reading: a noisy daemon may keep filling
        // them, so draining until EAGAIN could follow its output indefinitely.
        let stdoutBytes = try bufferedBytes(stdoutFD, open: stdoutOpen)
        let stderrBytes = try bufferedBytes(stderrFD, open: stderrOpen)
        try drain(stdoutFD, into: &output, open: &stdoutOpen, byteLimit: stdoutBytes)
        try drain(stderrFD, into: &errors, open: &stderrOpen, byteLimit: stderrBytes)
        return SubprocessRunner.Output(terminationStatus: exit.status ?? -1, standardOutput: output, standardError: errors)
    }

    private static func bufferedBytes(_ fd: Int32, open: Bool) throws -> Int {
        guard open else { return 0 }
        var bytes: Int32 = 0
        let error = banyan_command_buffered(fd, &bytes)
        guard error == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }
        return Int(bytes)
    }

    private static func drain(_ fd: Int32, into data: inout Data, open: inout Bool,
                              byteLimit: Int) throws {
        guard open else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        var remaining = byteLimit
        while remaining > 0 {
            let count = read(fd, &buffer, min(buffer.count, remaining))
            if count > 0 { data.append(contentsOf: buffer.prefix(count)); remaining -= count; continue }
            if count < 0 && errno == EINTR { continue }
            if count == 0 { open = false }
            if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return
        }
    }
}

/// One blocking waitid per command, with a self-pipe wakeup; no process polling.
/// The lock covers signalling and reaping, retaining PID ownership across both.
private final class CommandExit: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var result: Int32?
    private var writeFD: Int32
    let readFD: Int32
    private let finished = DispatchSemaphore(value: 0)

    init() throws {
        var ends: [Int32] = [-1, -1]
        guard pipe(&ends) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        readFD = ends[0]; writeFD = ends[1]
        for fd in ends {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }
    }

    var status: Int32? { lock.lock(); defer { lock.unlock() }; return result }

    func observe(_ child: pid_t) {
        pid = child
        DispatchQueue.global(qos: .utility).async { [self] in
            let status = banyan_pty_wait(child)
            lock.lock()
            pid = 0
            banyan_pty_reap(child)
            result = status
            if writeFD >= 0 {
                var byte: UInt8 = 1
                while write(writeFD, &byte, 1) < 0 && errno == EINTR {}
            }
            lock.unlock()
            finished.signal()
        }
    }

    func terminate() {
        signalOwned(SIGTERM)
        if finished.wait(timeout: .now() + .milliseconds(500)) == .success { return }
        signalOwned(SIGKILL)
        _ = finished.wait(timeout: .now() + 2)
        // If the kernel delays exit, observe still retains ownership and reaps it.
    }

    private func signalOwned(_ signal: Int32) {
        lock.lock(); defer { lock.unlock() }
        if pid > 0 { kill(pid, signal) }
    }

    func closeWakeup() {
        lock.lock(); defer { lock.unlock() }
        if writeFD >= 0 { close(writeFD); writeFD = -1 }
    }

    deinit { close(readFD); closeWakeup() }
}
