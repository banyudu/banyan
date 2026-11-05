import BanyanCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

if CommandLine.arguments.dropFirst().first == AgentProviderIdentity.helper {
    do {
        if CommandLine.arguments.count == 6, CommandLine.arguments[2] == "query",
           let pid = Int32(CommandLine.arguments[3]), let provider = CodingAgentProvider(rawValue: CommandLine.arguments[4]),
           let identity = AgentProcessSample.read(pid: pid)?.identity {
            guard let disk = try AgentProviderIdentity.query(process: identity, provider: provider, cwd: CommandLine.arguments[5]) else {
                throw AgentFreezeError.unsafe("Provider identity adapter is absent")
            }
            print(String(decoding: try JSONEncoder().encode(disk), as: UTF8.self)); exit(0)
        }
        if CommandLine.arguments.count == 5, CommandLine.arguments[2] == "wait" {
            guard let request = try AgentProviderIdentity.waitForRequest(directory: URL(fileURLWithPath: CommandLine.arguments[3]), excluding: CommandLine.arguments[4]) else { exit(75) }
            print(request); exit(0)
        }
        print(try AgentProviderIdentity.owningProviderPID()); exit(0)
    }
    catch {
        if CommandLine.arguments.dropFirst(2).first == "query" { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)) }
        exit(1)
    }
}

if CommandLine.arguments.dropFirst().first == AgentProcessHost.subcommand {
    let persistent = CommandLine.arguments.dropFirst(2).first == AgentProcessHost.persistentFlag
    let inherited = CommandLine.arguments.dropFirst(2).first == AgentProcessHost.inheritedFlag
    let offset = persistent || inherited ? 3 : 2
    guard CommandLine.arguments.count == offset + 2 else { exit(64) }
    do {
        if persistent {
            exit(try AgentProcessHost.runPersistent(shell: CommandLine.arguments[offset],
                command: CommandLine.arguments[offset + 1], executable: CommandLine.arguments[0]))
        }
        let original = CommandLine.arguments[offset + 1]
        var command = original
        if inherited {
            do { command = try AgentProviderIdentity.prepare(command: original, executable: CommandLine.arguments[0]) }
            catch { FileHandle.standardError.write(Data("[Banyan] Current-session adapter unavailable; deep suspension requires verified identity.\n".utf8)) }
        }
        let titleLaunch = AgentSessionTitleLaunch.prepare(command: command,
            executable: URL(fileURLWithPath: CommandLine.arguments[0]).path,
            environment: ProcessInfo.processInfo.environment)
        command = titleLaunch.command
        for (key, value) in titleLaunch.environment { setenv(key, value, 1) }
        exit(try AgentProcessHost.run(shell: CommandLine.arguments[offset], command: command, loginShell: !inherited))
    }
    catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        exit(1)
    }
}

let client = BanyanCtl(arguments: Array(CommandLine.arguments.dropFirst()))
client.run()
