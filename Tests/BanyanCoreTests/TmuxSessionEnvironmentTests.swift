import Foundation
import Testing
@testable import BanyanCore

@Test func tmuxRefreshesExistingSessionIdentityAndClearsGlobalInheritance() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-session-environment-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let executable = try #require(TmuxBackend.resolveExecutableURL(environment: ProcessInfo.processInfo.environment))
    let socket = "banyan-session-environment-\(UUID().uuidString)"
    let environment = [
        "HOME": root.path,
        "PATH": "/usr/bin:/bin",
        "SHELL": "/bin/sh",
        "TERM": "dumb"
    ]
    let backend = TmuxBackend(
        executableURL: executable,
        workingDirectory: root.path,
        environment: environment,
        socketName: socket
    )
    func runTmux(_ arguments: [String]) async throws -> String {
        let output = try await SubprocessRunner.runAsync(
            arguments: [executable.path, "-L", socket] + arguments,
            cwd: root.path,
            environment: environment,
            timeout: 10
        )
        try #require(output.terminationStatus == 0, "\(String(decoding: output.standardError, as: UTF8.self))")
        return String(decoding: output.standardOutput, as: UTF8.self)
    }
    defer {
        _ = try? SubprocessRunner.run(
            arguments: [executable.path, "-L", socket, "kill-server"],
            cwd: root.path,
            environment: environment,
            timeout: 10
        )
    }

    let name = "banyan-session-identity"
    try await runBlockingTestWork {
        try backend.ensureSession(
            named: name,
            cwd: root.path,
            command: "/bin/cat",
            banyanSessionID: "session-old"
        )
    }
    #expect(try await runTmux(["show-environment", "-t", name, BanyanSessionEnvironment.sessionIDKey])
        .trimmingCharacters(in: .whitespacesAndNewlines) == "BANYAN_SESSION_ID=session-old")

    // A surviving tmux server may still carry identity from the process that
    // started it, and an old session can retain a parent override. Both must be
    // removed the next time Banyan touches the server/session.
    _ = try await runTmux(["set-environment", "-g", BanyanSessionEnvironment.sessionIDKey, "session-global"])
    _ = try await runTmux(["set-environment", "-g", BanyanSessionEnvironment.parentSessionIDKey, "parent-global"])
    _ = try await runTmux(["set-environment", "-t", name, BanyanSessionEnvironment.sessionIDKey, "session-old"])
    _ = try await runTmux(["set-environment", "-t", name, BanyanSessionEnvironment.parentSessionIDKey, "parent-old"])

    try await runBlockingTestWork {
        try backend.ensureSession(
            named: name,
            cwd: root.path,
            command: "/bin/cat",
            banyanSessionID: "session-current"
        )
    }

    let sessionEnvironment = tmuxEnvironment(try await runTmux(["show-environment", "-t", name]))
    #expect(sessionEnvironment[BanyanSessionEnvironment.sessionIDKey] == "session-current")
    #expect(sessionEnvironment[BanyanSessionEnvironment.parentSessionIDKey] == nil)

    let globalEnvironment = tmuxEnvironment(try await runTmux(["show-environment", "-g"]))
    #expect(globalEnvironment[BanyanSessionEnvironment.sessionIDKey] == nil)
    #expect(globalEnvironment[BanyanSessionEnvironment.parentSessionIDKey] == nil)
}

private func tmuxEnvironment(_ output: String) -> [String: String] {
    output.split(separator: "\n").reduce(into: [:]) { values, line in
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            values[String(parts[0])] = String(parts[1])
        }
    }
}
