@testable import Banyan
import Testing

@Test func jumpIndexMapsDigitsToOneBasedPositions() {
    #expect(JumpOverlayMonitor.jumpIndex(for: "1") == 1)
    #expect(JumpOverlayMonitor.jumpIndex(for: "9") == 9)
    #expect(JumpOverlayMonitor.jumpIndex(for: "0") == nil)
}

@Test func jumpIndexMapsLettersSkippingReservedKeys() {
    #expect(JumpOverlayMonitor.jumpIndex(for: "a") == 10)
    #expect(JumpOverlayMonitor.jumpIndex(for: "b") == 11)
    #expect(JumpOverlayMonitor.jumpIndex(for: "i") == 18)
    // J and K are reserved for ⌘J/⌘K navigation
    #expect(JumpOverlayMonitor.jumpIndex(for: "j") == nil)
    #expect(JumpOverlayMonitor.jumpIndex(for: "k") == nil)
    // L follows I (skipping J, K)
    #expect(JumpOverlayMonitor.jumpIndex(for: "l") == 19)
    #expect(JumpOverlayMonitor.jumpIndex(for: "z") == 33)
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
    #expect(JumpOverlayMonitor.jumpLabel(for: 18) == "I")
    #expect(JumpOverlayMonitor.jumpLabel(for: 19) == "L")
    #expect(JumpOverlayMonitor.jumpLabel(for: 33) == "Z")
}

@Test func jumpLabelReturnsNilForOutOfRange() {
    #expect(JumpOverlayMonitor.jumpLabel(for: 0) == nil)
    #expect(JumpOverlayMonitor.jumpLabel(for: 34) == nil)
}

@Test func jumpLabelNeverIncludesReservedKeys() {
    for index in 1...33 {
        guard let label = JumpOverlayMonitor.jumpLabel(for: index) else { continue }
        #expect(label != "J")
        #expect(label != "K")
    }
}

@Test func jumpIndexAndLabelAreInverses() {
    // 9 digits + 24 letters (26 minus J, K) = 33 total
    for index in 1...33 {
        guard let label = JumpOverlayMonitor.jumpLabel(for: index) else {
            Issue.record("No label for index \(index)")
            continue
        }
        let char = Character(label.lowercased())
        #expect(JumpOverlayMonitor.jumpIndex(for: char) == index)
    }
}
