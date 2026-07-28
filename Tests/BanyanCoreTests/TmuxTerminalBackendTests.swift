import Foundation
import Testing
@testable import BanyanCore

@Test func tmuxBackendProvidesTheCompleteTerminalBackendSurface() {
    let backend: any TmuxTerminalBackend = TmuxBackend.shared
    #expect(backend.attachArguments(for: "banyan-one").contains("banyan-one"))
}
