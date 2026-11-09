import Foundation

/// `[Image #N]` placeholders in a Puck draft, as Codex's own composer writes
/// them. The draft's text decides which attachments a message carries: image
/// N is sent when its placeholder is in the text. Numbers stay put while the
/// draft is edited, so undoing a deleted placeholder brings its image back,
/// and are renumbered from 1 when the message is sent. puckd hands Codex the
/// images before the text, so `[Image #1]` is the first image the model sees.
///
/// Ranges are UTF-16 (`NSRange`), matching `NSTextView`.
enum PuckImagePlaceholders {
    struct Token: Equatable {
        let range: NSRange
        let number: Int
    }

    static func label(_ number: Int) -> String { "[Image #\(number)]" }

    private static let pattern = try! NSRegularExpression(pattern: #"\[Image #([1-9][0-9]{0,3})\]"#)

    /// Every placeholder in `text`, whether or not an image backs it.
    static func tokens(in text: String) -> [Token] {
        let string = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: string.length)).compactMap { match in
            Int(string.substring(with: match.range(at: 1))).map { Token(range: match.range, number: $0) }
        }
    }

    /// Placeholders that name one of `imageCount` attachments.
    static func references(in text: String, imageCount: Int) -> [Token] {
        tokens(in: text).filter { $0.number <= imageCount }
    }

    /// The attachment numbers `text` refers to, ascending and unique.
    static func referencedNumbers(in text: String, imageCount: Int) -> [Int] {
        Array(Set(references(in: text, imageCount: imageCount).map(\.number))).sorted()
    }

    /// The message to send: only the images the text names, renumbered from
    /// 1 in attachment order, with the text's placeholders rewritten to match.
    static func normalized<Image>(text: String, images: [Image]) -> (text: String, images: [Image], unused: [Image]) {
        let used = referencedNumbers(in: text, imageCount: images.count)
        let renumbered = Dictionary(uniqueKeysWithValues: used.enumerated().map { ($1, $0 + 1) })
        let rewritten = rewriting(text, imageCount: images.count) { renumbered[$0] }
        let unused = images.indices.filter { !used.contains($0 + 1) }.map { images[$0] }
        return (rewritten, used.map { images[$0 - 1] }, unused)
    }

    /// Joins drafts (queued messages, then the composer) into one, shifting
    /// each part's placeholders past the images of the parts before it.
    static func merged<Image>(_ parts: [(text: String, images: [Image])]) -> (text: String, images: [Image]) {
        var texts: [String] = []
        var images: [Image] = []
        for part in parts {
            let offset = images.count
            let shifted = rewriting(part.text, imageCount: part.images.count) { $0 + offset }
            if !shifted.isEmpty { texts.append(shifted) }
            images += part.images
        }
        return (texts.joined(separator: "\n\n"), images)
    }

    /// `text` without image `number`'s placeholders, each with one space
    /// beside it, so the words around it close up.
    static func removing(_ number: Int, from text: String) -> String {
        let result = NSMutableString(string: text)
        for token in tokens(in: text).reversed() where token.number == number {
            var range = token.range
            if NSMaxRange(range) < result.length, result.character(at: NSMaxRange(range)) == 0x20 {
                range.length += 1
            } else if range.location > 0, result.character(at: range.location - 1) == 0x20 {
                range.location -= 1
                range.length += 1
            }
            result.replaceCharacters(in: range, with: "")
        }
        return result as String
    }

    /// The text to insert for new attachments at `range`, spaced from the
    /// words on either side.
    static func insertion(of labels: [String], at range: NSRange, in text: String) -> String {
        let string = text as NSString
        var inserted = labels.joined(separator: " ")
        if range.location > 0, !isWhitespace(string.character(at: range.location - 1)) {
            inserted = " " + inserted
        }
        let end = NSMaxRange(range)
        if end >= string.length || !isWhitespace(string.character(at: end)) {
            inserted += " "
        }
        return inserted
    }

    /// An edit that touches part of a placeholder takes the whole one, and
    /// typing inside one moves after it: a placeholder edits as one unit.
    static func atomicRange(for range: NSRange, in text: String) -> NSRange {
        let tokens = tokens(in: text)
        if range.length == 0 {
            guard let inside = tokens.first(where: { strictlyInside(range.location, $0.range) }) else { return range }
            return NSRange(location: NSMaxRange(inside.range), length: 0)
        }
        return expanded(range, over: tokens)
    }

    /// Keeps the caret out of a placeholder's interior: moving forward or
    /// backward steps over it, a click lands on its nearer edge, and a
    /// selection covers whole placeholders.
    static func snappedSelection(_ proposed: NSRange, from previous: NSRange, in text: String) -> NSRange {
        let tokens = tokens(in: text)
        guard proposed.length == 0 else { return expanded(proposed, over: tokens) }
        guard let inside = tokens.first(where: { strictlyInside(proposed.location, $0.range) }) else { return proposed }
        let start = inside.range.location
        let end = NSMaxRange(inside.range)
        let location: Int
        if previous.location <= start {
            location = end
        } else if previous.location >= end {
            location = start
        } else {
            location = proposed.location - start < end - proposed.location ? start : end
        }
        return NSRange(location: location, length: 0)
    }

    private static func rewriting(_ text: String, imageCount: Int, _ number: (Int) -> Int?) -> String {
        let result = NSMutableString(string: text)
        for token in references(in: text, imageCount: imageCount).reversed() {
            guard let replacement = number(token.number) else { continue }
            result.replaceCharacters(in: token.range, with: label(replacement))
        }
        return result as String
    }

    private static func expanded(_ range: NSRange, over tokens: [Token]) -> NSRange {
        var start = range.location
        var end = NSMaxRange(range)
        for token in tokens {
            if strictlyInside(start, token.range) { start = token.range.location }
            if strictlyInside(end, token.range) { end = NSMaxRange(token.range) }
        }
        return NSRange(location: start, length: end - start)
    }

    private static func strictlyInside(_ location: Int, _ range: NSRange) -> Bool {
        location > range.location && location < NSMaxRange(range)
    }

    private static func isWhitespace(_ character: unichar) -> Bool {
        character == 0x20 || character == 0x0A || character == 0x09 || character == 0x0D
    }
}
