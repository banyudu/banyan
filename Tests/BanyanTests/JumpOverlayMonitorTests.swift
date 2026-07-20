@testable import Banyan
import Testing

@Test func jumpIndexMapsDigitsToOneBasedPositions() {
    #expect(JumpOverlayMonitor.jumpIndex(for: "1") == 1)
    #expect(JumpOverlayMonitor.jumpIndex(for: "9") == 9)
    #expect(JumpOverlayMonitor.jumpIndex(for: "0") == nil)
}

@Test func jumpIndexMapsAllLetters() {
    #expect(JumpOverlayMonitor.jumpIndex(for: "a") == 10)
    #expect(JumpOverlayMonitor.jumpIndex(for: "b") == 11)
    #expect(JumpOverlayMonitor.jumpIndex(for: "j") == 19)
    #expect(JumpOverlayMonitor.jumpIndex(for: "k") == 20)
    #expect(JumpOverlayMonitor.jumpIndex(for: "z") == 35)
}

@Test func jumpIndexRejectsInvalidCharacters() {
    #expect(JumpOverlayMonitor.jumpIndex(for: " ") == nil)
    #expect(JumpOverlayMonitor.jumpIndex(for: "!") == nil)
    #expect(JumpOverlayMonitor.jumpIndex(for: "A") == nil)
}

@Test func jumpLabelMapsPositionsToDisplayKeys() {
    #expect(JumpOverlayMonitor.jumpLabel(for: 1) == "1")
    #expect(JumpOverlayMonitor.jumpLabel(for: 9) == "9")
    #expect(JumpOverlayMonitor.jumpLabel(for: 10) == "A")
    #expect(JumpOverlayMonitor.jumpLabel(for: 19) == "J")
    #expect(JumpOverlayMonitor.jumpLabel(for: 20) == "K")
    #expect(JumpOverlayMonitor.jumpLabel(for: 35) == "Z")
}

@Test func jumpLabelReturnsNilForOutOfRange() {
    #expect(JumpOverlayMonitor.jumpLabel(for: 0) == nil)
    #expect(JumpOverlayMonitor.jumpLabel(for: 36) == nil)
}

@Test func jumpIndexAndLabelAreInverses() {
    for index in 1...35 {
        guard let label = JumpOverlayMonitor.jumpLabel(for: index) else {
            Issue.record("No label for index \(index)")
            continue
        }
        let char = Character(label.lowercased())
        #expect(JumpOverlayMonitor.jumpIndex(for: char) == index)
    }
}
