import BanyanCore
import Testing
@testable import BanyanTUI

@Test func terminalBytesDecodeIntoSharedSessionActions() {
    #expect(SessionListAction(byte: 104) == .toggleHistory)
    #expect(SessionListAction(byte: 10) == .activate)
    #expect(SessionListAction(byte: 101) == .rename)
    #expect(SessionListAction(byte: 78) == .newCustomSession)
    #expect(SessionListAction(byte: 47) == .searchHistory)
    #expect(SessionListAction(byte: 63) == .unknown)
}

@Test func terminalEscapeSequencesDecodeIntoNavigationActions() {
    #expect(SessionListAction(sequence: [27, 91, 65]) == .previous)
    #expect(SessionListAction(sequence: [27, 91, 66]) == .next)
    #expect(SessionListAction(sequence: [27, 91, 53, 126]) == .pagePrevious)
    #expect(SessionListAction(sequence: [27, 91, 54, 126]) == .pageNext)
}
