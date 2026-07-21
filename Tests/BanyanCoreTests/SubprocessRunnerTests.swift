import Foundation
import Testing
@testable import BanyanCore

@Test func subprocessRunnerDoesNotWaitForDrainTimeoutAfterExit() throws {
    let startedAt = ContinuousClock.now
    let output = try SubprocessRunner.run(
        arguments: ["printf", "ready"],
        cwd: FileManager.default.currentDirectoryPath,
        environment: ProcessInfo.processInfo.environment,
        timeout: 2
    )
    let elapsed = ContinuousClock.now - startedAt

    #expect(output.terminationStatus == 0)
    #expect(String(decoding: output.standardOutput, as: UTF8.self) == "ready")
    #expect(elapsed < .milliseconds(900))
}

@Test func subprocessRunnerReturnsGitOutputWithoutWaitingForDescendantEOF() throws {
    let cwd = FileManager.default.currentDirectoryPath
    let startedAt = ContinuousClock.now
    let output = try SubprocessRunner.run(
        arguments: ["git", "-C", cwd, "rev-parse", "--show-toplevel"],
        cwd: cwd,
        environment: ProcessInfo.processInfo.environment,
        timeout: 2
    )
    let elapsed = ContinuousClock.now - startedAt

    #expect(output.terminationStatus == 0)
    #expect(String(decoding: output.standardOutput, as: UTF8.self).contains("banyan"))
    #expect(elapsed < .milliseconds(900))
}
