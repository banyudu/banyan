import Foundation

/// A deterministic stand-in for coding-agent output: mixed plain text, SGR
/// colour runs, detectable URLs (Banyan turns implicit link detection on, which
/// is the most expensive part of building a line), box-drawing progress bars,
/// and the occasional full-screen repaint that a tmux client performs.
///
/// Seeded, so both arms of an A/B replay byte-for-byte the same stream.
struct WorkloadGenerator {
    /// `stream` scrolls the buffer, which is what agent output does.
    /// `staticScreen` repaints the alternate screen in place, which is what a
    /// full-screen TUI does: the viewport never moves, so a renderer that keys
    /// its caches on the scroll offset keeps them.
    enum Kind: String {
        case stream
        case staticScreen = "static"
    }

    private var state: UInt64
    private let kind: Kind
    private let rows: Int
    private var hasEnteredAlternateScreen = false

    init(seed: UInt64, kind: Kind = .stream, rows: Int = 24) {
        state = seed == 0 ? 0x2545_F491_4F6C_DD1D : seed
        self.kind = kind
        self.rows = max(4, rows)
    }

    private mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 11
    }

    private mutating func next(_ upperBound: Int) -> Int {
        Int(next() % UInt64(max(1, upperBound)))
    }

    private static let words = [
        "session", "terminal", "renderer", "buffer", "atlas", "glyph", "commit",
        "branch", "worktree", "telemetry", "sqlite", "throttle", "coalesce",
        "scrollback", "selection", "pipeline", "texture", "vertex", "quad",
        "energy", "impact", "sample", "percentile", "baseline", "regression"
    ]

    private static let urls = [
        "https://example.com/org/repo/issues/79",
        "https://example.com/docs/metal/renderer",
        "https://example.com/build/1234/logs"
    ]

    /// One line of output, already terminated with CRLF.
    mutating func line() -> String {
        switch next(100) {
        case 0..<3:
            // A tmux-style full screen repaint.
            var repaint = "\u{1b}[H\u{1b}[2J"
            for _ in 0..<8 {
                repaint += plainLine()
            }
            return repaint
        case 3..<13:
            return "  \u{1b}[38;5;\(33 + next(6))m\(Self.urls[next(Self.urls.count)])\u{1b}[0m \(word()) \(word())\r\n"
        case 13..<23:
            let filled = next(30)
            let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: 30 - filled)
            return "  ┌\(String(repeating: "─", count: 32))┐\r\n  │\(bar)│ \(filled * 100 / 30)%\r\n  └\(String(repeating: "─", count: 32))┘\r\n"
        case 23..<48:
            var coloured = "  "
            for _ in 0..<(3 + next(6)) {
                coloured += "\u{1b}[38;5;\(next(256))m\(word())\u{1b}[0m "
            }
            return coloured + "\r\n"
        default:
            return plainLine()
        }
    }

    private mutating func plainLine() -> String {
        var text = "  "
        for _ in 0..<(4 + next(14)) {
            text += word() + " "
        }
        return text + "\r\n"
    }

    private mutating func word() -> String {
        Self.words[next(Self.words.count)]
    }

    /// One full repaint of the alternate screen, cursor-addressed so the buffer
    /// never scrolls.
    private mutating func screen() -> String {
        var frame = ""
        if !hasEnteredAlternateScreen {
            frame += "\u{1b}[?1049h"
            hasEnteredAlternateScreen = true
        }
        frame += "\u{1b}[H"
        for row in 0..<(rows - 1) {
            frame += "\u{1b}[\(row + 1);1H\u{1b}[K"
            frame += String(line().dropLast(2))
        }
        return frame
    }

    /// The next chunk of at least `minimumBytes` bytes, always ending on a line
    /// or frame boundary so a chunk boundary can never change how the stream
    /// parses.
    mutating func chunk(minimumBytes: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(minimumBytes + 128)
        while bytes.count < minimumBytes {
            switch kind {
            case .stream:
                bytes.append(contentsOf: Array(line().utf8))
            case .staticScreen:
                bytes.append(contentsOf: Array(screen().utf8))
            }
        }
        return bytes
    }
}
