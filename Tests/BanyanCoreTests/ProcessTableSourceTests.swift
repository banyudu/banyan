import Foundation
import Testing
@testable import BanyanCore

@Test func executablePathNamesTheTrailingComponentWithoutTouchingTheFilesystem() {
    #expect(ExecutablePath.lowercasedName("/opt/homebrew/bin/TMUX") == "tmux")
    #expect(ExecutablePath.lowercasedName("claude") == "claude")
    #expect(ExecutablePath.lowercasedName("/usr/local/bin/node/") == "node")
    #expect(ExecutablePath.lowercasedName("relative/path/opencode") == "opencode")
    // `URL(fileURLWithPath:)` answers an empty path with the *working
    // directory's* last component; a name derived from the string cannot.
    #expect(ExecutablePath.lowercasedName("") == "")
    #expect(ExecutablePath.lowercasedName("/") == "")
}

@Test func commandLineScanMatchesMarkersAcrossTheCommandAndItsArguments() {
    let scan = CommandLineScan(
        commandName: "/opt/homebrew/bin/Node",
        arguments: "node /Users/example/.npm/_npx/server-filesystem/dist/MCP-server.js"
    )
    #expect(scan.contains(CommandLineMarker("mcp-server")))
    #expect(scan.contains(CommandLineMarker("/node")))
    #expect(!scan.contains(CommandLineMarker("modelcontextprotocol")))
    #expect(scan.contains(anyOf: [CommandLineMarker("cua_node"), CommandLineMarker("mcp_server"), CommandLineMarker("/mcp")]))
    #expect(!scan.contains(anyOf: [CommandLineMarker("cua_node"), CommandLineMarker("mcp_server"), CommandLineMarker("-mcp")]))

    // The command and the argument line are joined by a space, so a marker that
    // begins with one still matches the first argument.
    #expect(CommandLineScan(commandName: "/bin/foo", arguments: "mcpd --stdio")
        .contains(CommandLineMarker(" mcp")))
    #expect(CommandLineScan(commandName: "mcp-proxy", arguments: "")
        .hasPrefix(CommandLineMarker("mcp")))
    #expect(!CommandLineScan(commandName: "/bin/zsh", arguments: "-lc claude")
        .hasPrefix(CommandLineMarker("mcp")))
}

@Test func processRowsClassifyToolingHiddenBehindALongInstallPath() {
    // `ps -o comm=` truncates to 16 characters, so these names used to arrive as
    // `/opt/homebrew/bi` and classified as nothing at all.
    let tmux = ProcessInfoRow(
        pid: 2, parentPID: 1, state: "S", elapsed: 1,
        commandName: "/opt/homebrew/bin/tmux",
        arguments: "/opt/homebrew/bin/tmux -L banyan new-session -d -s banyan-session-1"
    )
    #expect(tmux.isTmuxPlumbing)

    let node = ProcessInfoRow(
        pid: 3, parentPID: 2, state: "S", elapsed: 1,
        commandName: "/Users/example/.nvm/versions/node/v22.14.0/bin/node",
        arguments: "node /Users/example/.local/bin/claude"
    )
    #expect(node.isNodeAgentLauncher)
    #expect(node.supportedAgentProvider == .claude)

    let shell = ProcessInfoRow(
        pid: 4, parentPID: 2, state: "S", elapsed: 1,
        commandName: "/opt/homebrew/bin/bash",
        arguments: "bash -lc codex"
    )
    #expect(shell.isShellOrWrapper)
}

@Test func processTableResolvesCommandLinesOnlyForTheRequestedSubtree() {
    let table = ProcessTable(rows: [
        ProcessInfoRow(pid: 100, parentPID: 1, state: "S", elapsed: 9, commandName: "/bin/zsh", arguments: "-lc claude"),
        ProcessInfoRow(pid: 101, parentPID: 100, state: "S", elapsed: 5, commandName: "/usr/local/bin/claude", arguments: "claude"),
        ProcessInfoRow(pid: 200, parentPID: 1, state: "S", elapsed: 5, commandName: "/usr/local/bin/codex", arguments: "codex")
    ])

    let descendants = table.descendants(of: 100)
    #expect(descendants.map(\.pid).sorted() == [100, 101])
    #expect(descendants.first { $0.pid == 101 }?.supportedAgentProvider == .claude)
    // Caller-supplied rows keep the command line they were built with.
    #expect(descendants.first { $0.pid == 100 }?.arguments == "-lc claude")
    #expect(descendants.first { $0.pid == 100 }?.elapsed == 9)
    #expect(descendants.first { $0.pid == 100 }?.state == "S")
}

@Test func platformProcessTableReportsParentsAndUntruncatedExecutablePaths() {
    let rows = ProcessInfoRow.load()

    #expect(!rows.isEmpty)
    #expect(rows.contains { $0.pid > 0 && $0.elapsed >= 0 && !$0.commandName.isEmpty })
    #expect(rows.contains { $0.pid > 1 && $0.parentPID > 0 })

    #if os(macOS)
    // The kernel reader exists to escape `ps -o comm=`'s 16-character cap; on a
    // Mac essentially every Homebrew or nvm binary is longer than that.
    #expect(rows.contains { $0.commandName.count > 16 && $0.commandName.hasPrefix("/") })
    #endif
}

@Test func exitedProcessesAreNeitherLiveAgentsNorWorkInFlight() {
    // The kernel keeps a reaped-pending process's name, so a zombie `claude`
    // reads exactly like a running one until its state is consulted.
    let zombie = ProcessInfoRow(
        pid: 101, parentPID: 100, state: "Z", elapsed: 30,
        commandName: "/usr/local/bin/claude",
        arguments: "claude"
    )
    #expect(zombie.isExited)
    #expect(!zombie.isSupportedAgent)

    let live = ProcessInfoRow(
        pid: 102, parentPID: 100, state: "S", elapsed: 30,
        commandName: "/usr/local/bin/claude",
        arguments: "claude"
    )
    #expect(!live.isExited)
    #expect(live.isSupportedAgent)
}
