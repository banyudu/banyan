import Foundation
import Testing
@testable import Banyan

/// `[Image #N]` placeholders: which images a draft sends, how they are
/// renumbered, and how the field edits them as one unit.
struct PuckImagePlaceholdersTests {
    private typealias P = PuckImagePlaceholders

    @Test func onlyPlaceholdersBackedByAnAttachmentCount() {
        let text = "See [Image #1], [Image #3] and [Image #0] or [image #2]"
        #expect(P.tokens(in: text).map(\.number) == [1, 3])
        #expect(P.referencedNumbers(in: text, imageCount: 2) == [1])
        #expect(P.referencedNumbers(in: "[Image #2] [Image #2]", imageCount: 2) == [2])
    }

    @Test func sendingKeepsNamedImagesAndRenumbersThemFromOne() {
        let message = P.normalized(text: "Compare [Image #3] with [Image #2]; ignore [Image #9]",
                                   images: ["a", "b", "c"])
        #expect(message.text == "Compare [Image #2] with [Image #1]; ignore [Image #9]")
        #expect(message.images == ["b", "c"])
        #expect(message.unused == ["a"])

        let plain = P.normalized(text: "no images", images: ["a"])
        #expect(plain.text == "no images" && plain.images.isEmpty && plain.unused == ["a"])
    }

    @Test func mergedDraftsShiftLaterPlaceholdersPastEarlierImages() {
        let merged = P.merged([
            (text: "first [Image #1]", images: ["q1"]),
            (text: "", images: [String]()),
            (text: "draft [Image #1] [Image #2] [Image #5]", images: ["d1", "d2"]),
        ])
        #expect(merged.text == "first [Image #1]\n\ndraft [Image #2] [Image #3] [Image #5]")
        #expect(merged.images == ["q1", "d1", "d2"])
    }

    @Test func removingAnImageClosesUpItsWords() {
        #expect(P.removing(1, from: "look [Image #1] here") == "look here")
        #expect(P.removing(1, from: "look [Image #1]") == "look")
        #expect(P.removing(2, from: "[Image #2] [Image #1] x [Image #2]") == "[Image #1] x")
    }

    @Test func insertedPlaceholdersAreSpacedFromTheirNeighbors() {
        #expect(P.insertion(of: ["[Image #1]"], at: NSRange(location: 0, length: 0), in: "") == "[Image #1] ")
        #expect(P.insertion(of: ["[Image #1]", "[Image #2]"], at: NSRange(location: 4, length: 0), in: "look")
                == " [Image #1] [Image #2] ")
        #expect(P.insertion(of: ["[Image #1]"], at: NSRange(location: 5, length: 0), in: "look here")
                == "[Image #1] ")
        #expect(P.insertion(of: ["[Image #1]"], at: NSRange(location: 4, length: 1), in: "look here")
                == " [Image #1] ")
    }

    @Test func editsThatTouchAPlaceholderTakeAllOfIt() {
        let text = "a [Image #1] b"  // the placeholder spans 2..<12
        #expect(P.atomicRange(for: NSRange(location: 11, length: 1), in: text) == NSRange(location: 2, length: 10))
        #expect(P.atomicRange(for: NSRange(location: 0, length: 4), in: text) == NSRange(location: 0, length: 12))
        #expect(P.atomicRange(for: NSRange(location: 5, length: 0), in: text) == NSRange(location: 12, length: 0))
        #expect(P.atomicRange(for: NSRange(location: 12, length: 1), in: text) == NSRange(location: 12, length: 1))
        #expect(P.atomicRange(for: NSRange(location: 2, length: 0), in: text) == NSRange(location: 2, length: 0))
    }

    @Test func theCaretStepsOverAPlaceholder() {
        let text = "a [Image #1] b"
        let caret = { (location: Int) in NSRange(location: location, length: 0) }
        #expect(P.snappedSelection(caret(3), from: caret(2), in: text) == caret(12))
        #expect(P.snappedSelection(caret(11), from: caret(12), in: text) == caret(2))
        #expect(P.snappedSelection(caret(4), from: caret(0), in: text) == caret(12))
        #expect(P.snappedSelection(caret(4), from: caret(14), in: text) == caret(2))
        #expect(P.snappedSelection(caret(13), from: caret(12), in: text) == caret(13))
        #expect(P.snappedSelection(NSRange(location: 5, length: 9), from: caret(14), in: text)
                == NSRange(location: 2, length: 12))
    }
}
