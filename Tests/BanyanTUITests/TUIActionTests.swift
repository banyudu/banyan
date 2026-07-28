import BanyanCore
import Testing
@testable import BanyanTUI

@Test func terminalBytesDecodeIntoSharedSessionActions() {
    #expect(SessionListAction(byte: 104) == .toggleHistory)
    #expect(SessionListAction(byte: 10) == .activate)
    #expect(SessionListAction(byte: 63) == .unknown)
}
