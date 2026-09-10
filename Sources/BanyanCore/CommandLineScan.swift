import Foundation

/// An ASCII marker, pre-lowered to bytes so a scan never rebuilds it.
struct CommandLineMarker: Sendable {
    let bytes: [UInt8]

    init(_ text: String) {
        bytes = Array(text.lowercased().utf8)
    }
}

/// A process's executable and argument line, lowercased once into a byte buffer
/// so the classifier can test many markers against it without allocating a
/// `String` per test.
///
/// `String.contains` walks graphemes and `range(of:options:.caseInsensitive)`
/// bridges to `NSString`; both cost far more than the ASCII markers the
/// supervisor looks for actually need. Scanning bytes is ~30x cheaper than the
/// lowercased-haystack form it replaces and matches it exactly, including the
/// space that joins the two halves.
struct CommandLineScan {
    private let bytes: [UInt8]

    init(commandName: String, arguments: String) {
        var buffer: [UInt8] = []
        buffer.reserveCapacity(commandName.utf8.count + arguments.utf8.count + 1)
        for byte in commandName.utf8 { buffer.append(Self.lowered(byte)) }
        buffer.append(UInt8(ascii: " "))
        for byte in arguments.utf8 { buffer.append(Self.lowered(byte)) }
        self.bytes = buffer
    }

    func contains(_ marker: CommandLineMarker) -> Bool {
        let needle = marker.bytes
        guard !needle.isEmpty, bytes.count >= needle.count else { return false }
        let first = needle[0]
        let last = bytes.count - needle.count
        var index = 0
        while index <= last {
            if bytes[index] == first {
                var offset = 1
                while offset < needle.count, bytes[index &+ offset] == needle[offset] {
                    offset &+= 1
                }
                if offset == needle.count { return true }
            }
            index &+= 1
        }
        return false
    }

    func contains(anyOf markers: [CommandLineMarker]) -> Bool {
        markers.contains(where: contains)
    }

    func hasPrefix(_ marker: CommandLineMarker) -> Bool {
        guard bytes.count >= marker.bytes.count else { return false }
        return !zip(bytes, marker.bytes).contains { $0 != $1 }
    }

    private static func lowered(_ byte: UInt8) -> UInt8 {
        byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z") ? byte &+ 32 : byte
    }
}
