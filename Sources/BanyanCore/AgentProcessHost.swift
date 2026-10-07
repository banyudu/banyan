import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private var hostedProcessGroup: pid_t = 0

/// tmux automatically continues its pane-root process when that process stops.
/// Keep a small, waiting host as the pane root and give the command its own
/// foreground group. waitpid without WUNTRACED keeps the host asleep on STOP.
public enum AgentProcessHost {
    public static let subcommand = "__process-host"

    public static func executableURL(environment: [String: String]) -> URL? {
        #if os(macOS)
        if let path = environment["BANYAN_PROCESS_HOST"], FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        guard var directory = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        // App bundle sibling, SwiftPM product sibling, and nested XCTest helper.
        for _ in 0..<6 {
            let candidate = directory.appendingPathComponent("banyanctl")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            directory.deleteLastPathComponent()
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Called before constructing the CLI/control client. No network or app state.
    public static func run(shell: String, command: String) throws -> Int32 {
        let arguments = [shell, "-lc", command]
        let argv = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        #if canImport(Darwin)
        var attributes: posix_spawnattr_t?
        #else
        var attributes = posix_spawnattr_t()
        #endif
        guard posix_spawnattr_init(&attributes) == 0 else {
            throw AgentFreezeError.unsafe("Could not initialize process host")
        }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for value in [SIGINT, SIGQUIT, SIGHUP, SIGTERM, SIGTTIN, SIGTTOU, SIGTSTP] { sigaddset(&defaults, value) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        // Block forwarding signals before spawn, install the handlers, publish
        // the child group, then unblock. A HUP/TERM in the spawn window is
        // delivered to the new group rather than killing an unarmed host.
        var forwarding = sigset_t()
        sigemptyset(&forwarding)
        sigaddset(&forwarding, SIGHUP)
        sigaddset(&forwarding, SIGTERM)
        var originalMask = sigset_t()
        sigprocmask(SIG_BLOCK, &forwarding, &originalMask)
        defer { sigprocmask(SIG_SETMASK, &originalMask, nil) }
        for value in [SIGHUP, SIGTERM] {
            signal(value) { received in
                let group = hostedProcessGroup
                if group > 1 {
                    // Teardown must wake a stopped command so it can handle
                    // HUP/TERM. Ordinary STOP/TSTP never triggers an auto-CONT.
                    kill(-group, SIGCONT)
                    kill(-group, received)
                }
            }
        }
        // The host stays in the background once the child's group owns the TTY.
        signal(SIGTTIN, SIG_IGN)
        signal(SIGTTOU, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        signal(SIGQUIT, SIG_IGN)
        var child: pid_t = 0
        let status = argv.withUnsafeBufferPointer { buffer in
            posix_spawn(&child, shell, nil, &attributes, buffer.baseAddress!, environ)
        }
        guard status == 0 else { throw AgentFreezeError.unsafe("Could not launch hosted command: \(String(cString: strerror(status)))") }
        hostedProcessGroup = child
        if isatty(STDIN_FILENO) != 0 {
            guard tcsetpgrp(STDIN_FILENO, child) == 0 else {
                kill(-child, SIGKILL)
                var ignored: Int32 = 0
                waitpid(child, &ignored, 0)
                throw AgentFreezeError.unsafe("Could not give hosted command the foreground terminal")
            }
            // A child can reach stdin between spawn and tcsetpgrp and get TTIN.
            kill(-child, SIGCONT)
        }
        sigprocmask(SIG_SETMASK, &originalMask, nil)
        var waitStatus: Int32 = 0
        while waitpid(child, &waitStatus, 0) < 0 {
            if errno != EINTR { throw AgentFreezeError.unsafe("Could not wait for hosted command") }
        }
        sigprocmask(SIG_BLOCK, &forwarding, nil)
        hostedProcessGroup = 0
        if isatty(STDIN_FILENO) != 0 { _ = tcsetpgrp(STDIN_FILENO, getpgrp()) }
        // POSIX wait status macros are not imported into Swift.
        return waitStatus & 0x7f == 0 ? (waitStatus >> 8) & 0xff : 128 + (waitStatus & 0x7f)
    }
}
