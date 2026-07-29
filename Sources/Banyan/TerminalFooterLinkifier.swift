import Foundation

enum TerminalFooterLinkifier {
    private static let linkPrefix = "banyan-pr://"
    private static let pattern = try! NSRegularExpression(pattern: #"PR #(\d+)"#)

    static func annotate(_ slice: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        let bytes = Array(slice)
        let marker = Array("PR #".utf8)
        let prefix = Array("\u{001B}]8;;banyan-pr://".utf8)
        let suffix = Array("\u{001B}]8;;\u{0007}".utf8)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count + 32)
        var index = 0
        while index < bytes.count {
            guard index + marker.count <= bytes.count,
                  Array(bytes[index..<(index + marker.count)]) == marker else {
                output.append(bytes[index])
                index += 1
                continue
            }
            var end = index + marker.count
            while end < bytes.count, bytes[end] >= 48, bytes[end] <= 57 { end += 1 }
            guard end > index + marker.count else {
                output.append(bytes[index])
                index += 1
                continue
            }
            output.append(contentsOf: prefix)
            output.append(contentsOf: bytes[(index + marker.count)..<end])
            output.append(7)
            output.append(contentsOf: bytes[index..<end])
            output.append(contentsOf: suffix)
            index = end
        }
        return output[...]
    }

    static func annotate(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var output = ""
        var cursor = text.startIndex
        for match in pattern.matches(in: text, range: range) {
            guard let matchRange = Range(match.range, in: text),
                  let numberRange = Range(match.range(at: 1), in: text) else {
                continue
            }
            output += text[cursor..<matchRange.lowerBound]
            output += "\u{001B}]8;;\(linkPrefix)\(text[numberRange])\u{0007}"
            output += text[matchRange]
            output += "\u{001B}]8;;\u{0007}"
            cursor = matchRange.upperBound
        }
        output += text[cursor...]
        return output
    }

    static func pullRequestNumber(in link: String) -> Int? {
        guard link.hasPrefix(linkPrefix) else { return nil }
        return Int(link.dropFirst(linkPrefix.count))
    }
}
