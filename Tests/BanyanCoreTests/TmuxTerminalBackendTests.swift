import Foundation
import Testing
@testable import BanyanCore

@Test func tmuxBackendProvidesTheCompleteTerminalBackendSurface() {
    let backend: any TmuxTerminalBackend = TmuxBackend(
        environment: ProcessInfo.processInfo.environment,
        workingDirectory: FileManager.default.currentDirectoryPath
    )
    #expect(backend.attachArguments(for: "banyan-one").contains("banyan-one"))
}
