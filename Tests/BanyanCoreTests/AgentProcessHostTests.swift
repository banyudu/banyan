import Foundation
import Testing
@testable import BanyanCore

#if os(macOS)
@Test func agentProcessHostPreservesTerminalAndSignalLifecycle() throws {
    let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let executable = package.appendingPathComponent(".build/debug/banyanctl")
    try #require(FileManager.default.isExecutableFile(atPath: executable.path))
    var environment = ProcessInfo.processInfo.environment
    environment["BANYAN_PROCESS_HOST"] = executable.path
    let result = try SubprocessRunner.run(arguments: ["/usr/bin/python3", package.appendingPathComponent("scripts/tests/test_agent_process_host.py").path],
        cwd: package.path, environment: environment, timeout: 90)
    #expect(result.terminationStatus == 0, "\(String(decoding: result.standardError + result.standardOutput, as: UTF8.self))")
}
#endif
