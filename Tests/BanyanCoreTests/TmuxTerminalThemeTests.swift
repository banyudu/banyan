import Foundation
import Testing
@testable import BanyanCore

@Test func tmuxAppliesThemeBeforeFirstPaneStartsAndUpdatesExistingSessions() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-theme-order-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let tmux = TmuxBackend(
        environment: ProcessInfo.processInfo.environment,
        workingDirectory: root.path
    ).executableURL
    let wrapper = root.appendingPathComponent("tmux")
    let commandLog = root.appendingPathComponent("commands")
    try """
    #!/bin/sh
    printf '%s\\n' "$*" >> \(themeTestQuote(commandLog.path))
    exec \(themeTestQuote(tmux.path)) -f /dev/null "$@"

    """.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

    let socket = "banyan-theme-order-\(UUID().uuidString)"
    let environment = [
        "HOME": root.path,
        "PATH": "/usr/bin:/bin",
        "SHELL": "/bin/sh",
        "TERM": "dumb"
    ]
    let backend = TmuxBackend(
        executableURL: wrapper,
        workingDirectory: root.path,
        environment: environment,
        socketName: socket
    )
    func runTmux(_ arguments: [String]) async throws -> String {
        let output = try await SubprocessRunner.runAsync(
            arguments: [wrapper.path, "-L", socket] + arguments,
            cwd: root.path,
            environment: environment,
            timeout: 10
        )
        try #require(output.terminationStatus == 0, "\(String(decoding: output.standardError, as: UTF8.self))")
        return String(decoding: output.standardOutput, as: UTF8.self)
    }
    defer {
        _ = try? SubprocessRunner.run(
            arguments: [wrapper.path, "-L", socket, "kill-server"],
            cwd: root.path,
            environment: environment,
            timeout: 10
        )
    }

    let initialStyle = "fg=#abcdef,bg=#012345"
    let request = SessionLaunchRequest(
        sessionName: "banyan-theme-target",
        cwd: root.path,
        command: "exec /bin/sleep 30",
        banyanSessionID: "theme-target",
        terminalThemeStyle: initialStyle
    )
    try await runBlockingTestWork {
        try backend.ensureSession(request)
    }

    var commands = try String(contentsOf: commandLog, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    let createIndex = try #require(commands.firstIndex {
        $0.contains("new-session -d -s banyan-theme-target")
    })
    let globalThemeIndex = try #require(commands.firstIndex {
        $0.contains("set-option -g window-style \(initialStyle)")
    })
    #expect(globalThemeIndex < createIndex)

    let sessionThemeIndex = try #require(commands.firstIndex {
        $0.contains("set-option -t banyan-theme-target window-style \(initialStyle)")
    })
    #expect(createIndex < sessionThemeIndex)
    #expect(try await runTmux(["show-options", "-gv", "window-style"])
        .trimmingCharacters(in: .whitespacesAndNewlines) == initialStyle)
    #expect(try await runTmux(["show-options", "-t", request.sessionName, "-v", "window-style"])
        .trimmingCharacters(in: .whitespacesAndNewlines) == initialStyle)
    #expect(try await runTmux(["show-options", "-gv", "default-terminal"])
        .trimmingCharacters(in: .whitespacesAndNewlines) == "tmux-256color")

    let updatedStyle = "fg=#111213,bg=#fefefe"
    try await runBlockingTestWork {
        try backend.ensureSession(SessionLaunchRequest(
            sessionName: request.sessionName,
            cwd: request.cwd,
            command: request.command,
            banyanSessionID: request.banyanSessionID,
            terminalThemeStyle: updatedStyle
        ))
    }
    commands = try String(contentsOf: commandLog, encoding: .utf8)
        .split(separator: "\n")
        .map(String.init)
    #expect(commands.filter { $0.contains("new-session -d -s banyan-theme-target") }.count == 1)
    #expect(try await runTmux(["show-options", "-t", request.sessionName, "-v", "window-style"])
        .trimmingCharacters(in: .whitespacesAndNewlines) == updatedStyle)
}

private func themeTestQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
