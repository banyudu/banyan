import Foundation
import Testing
@testable import BanyanCore

@Test(.serialized, arguments: [nil, "", "1"] as [String?])
func tmuxFreshPaneAdvertisesColorWithoutForcingIt(noColor: String?) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("banyan-color-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let tmux = TmuxBackend(
        environment: ProcessInfo.processInfo.environment,
        workingDirectory: root.path
    ).executableURL
    // Disable user tmux configuration and user shell profiles. Each case owns its
    // socket, so neither setup nor cleanup can reach the app or another test.
    let wrapper = root.appendingPathComponent("tmux")
    let commandLog = root.appendingPathComponent("commands")
    let processEnvironment = root.appendingPathComponent("tmux.env")
    try """
    #!/bin/sh
    printf '%s\\n' "$*" >> \(colorTestQuote(commandLog.path))
    if [ "$4" = list-sessions ]; then /usr/bin/env > \(colorTestQuote(processEnvironment.path)); fi
    exec \(colorTestQuote(tmux.path)) -f /dev/null "$@"

    """.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    let socket = "banyan-color-test-\(UUID().uuidString)"
    var environment = [
        "HOME": root.path,
        "PATH": "/usr/bin:/bin",
        "SHELL": "/bin/sh",
        "TERM": "dumb",
        "COLORTERM": "old-value",
        "CLICOLOR": "0"
    ]
    environment["NO_COLOR"] = noColor
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

    let paneEnvironment = root.appendingPathComponent("pane.env")
    let tty = root.appendingPathComponent("tty")
    let command = """
    /usr/bin/env > \(colorTestQuote(paneEnvironment.path)); \
    if [ -t 0 ] && [ -t 1 ] && [ -t 2 ]; then echo yes > \(colorTestQuote(tty.path)); fi; \
    \(colorTestQuote(wrapper.path)) -L \(colorTestQuote(socket)) wait-for -S color-probe; \
    exec /bin/cat
    """
    try await runBlockingTestWork {
        try backend.ensureSession(named: "color-probe", cwd: root.path, command: command)
    }
    // wait-for remembers an early signal, avoiding a sleep/poll race with the pane.
    _ = try await runTmux(["wait-for", "color-probe"])
    // Also exercise the existing-server path used when the frontend attaches.
    try await runBlockingTestWork {
        try backend.ensureSession(named: "color-probe", cwd: root.path, command: command)
    }

    let global = colorTestEnvironment(try await runTmux(["show-environment", "-g"]))
    let pane = colorTestEnvironment(try String(contentsOf: paneEnvironment, encoding: .utf8))
    let process = colorTestEnvironment(try String(contentsOf: processEnvironment, encoding: .utf8))
    for values in [process, global, pane] {
        #expect(values["CLICOLOR_FORCE"] == nil)
        #expect(values["FORCE_COLOR"] == nil)
        #expect(values["CLICOLOR"] == "1")
        #expect(values["COLORTERM"] == "truecolor")
        #expect(values["NO_COLOR"] == noColor)
    }
    #expect(process["TERM"] == TmuxBackend.attachTermName)
    #expect(global["TERM"] == TmuxBackend.attachTermName)
    let commands = try String(contentsOf: commandLog, encoding: .utf8)
    #expect(commands.contains("set-option -g default-terminal tmux-256color"))
    #expect(commands.contains("set-environment -g COLORTERM truecolor"))
    #expect(commands.contains("set-environment -g CLICOLOR 1"))
    #expect(!commands.contains("CLICOLOR_FORCE"))
    #expect(!commands.contains("FORCE_COLOR"))
    #expect(!commands.contains("NO_COLOR"))
    // Older tmux versions have a different cold-start default; compare the
    // pane with the server's effective TERM as well as checking the setting above.
    let defaultTerminal = try await runTmux(["show-options", "-gv", "default-terminal"])
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(pane["TERM"] == defaultTerminal)
    let terminalOverrides = try await runTmux(["show-options", "-gv", "terminal-overrides"])
    #expect(terminalOverrides.contains("xterm-256color:RGB"))
    let updateEnvironment = try await runTmux(["show-options", "-gv", "update-environment"])
    #expect(!updateEnvironment.contains("CLICOLOR_FORCE"))
    #expect(!updateEnvironment.contains("FORCE_COLOR"))
    #expect(try String(contentsOf: tty, encoding: .utf8) == "yes\n")
}

private func colorTestEnvironment(_ output: String) -> [String: String] {
    output.split(separator: "\n").reduce(into: [:]) { values, line in
        let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            values[String(parts[0])] = String(parts[1])
        }
    }
}

private func colorTestQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
