import AppKit
import BanyanCore
import SwiftUI
import SwiftTerm

extension TmuxBackend {
    func configureTerminalTheme(_ theme: TerminalTheme, for sessionName: String? = nil) {
        configureTerminalTheme(style: theme.tmuxDefaultStyle, for: sessionName)
    }
}

enum TerminalTheme: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    static func fromPersistedRawValue(_ rawValue: String?) -> TerminalTheme? {
        guard let rawValue else { return nil }
        if let theme = TerminalTheme(rawValue: rawValue) {
            return theme
        }
        switch rawValue {
        case "solarizedDark", "dracula":
            return .dark
        case "solarizedLight":
            return .light
        default:
            return nil
        }
    }

    var backgroundColor: NSColor {
        switch self {
        case .system:
            return NSColor.textBackgroundColor
        case .dark:
            return NSColor(red: 0.055, green: 0.060, blue: 0.070, alpha: 1)
        case .light:
            return NSColor(red: 0.995, green: 0.995, blue: 0.990, alpha: 1)
        }
    }

    var foregroundColor: NSColor? {
        switch self {
        case .system:
            return nil
        case .dark:
            return NSColor(red: 0.870, green: 0.885, blue: 0.900, alpha: 1)
        case .light:
            return NSColor(red: 0.105, green: 0.115, blue: 0.135, alpha: 1)
        }
    }

    /// The default colors exposed through tmux to applications running in the pane.
    ///
    /// Codex queries OSC 10/11 to choose its adaptive styles. Keeping tmux's pane
    /// defaults in sync with SwiftTerm lets that query work even though tmux is
    /// the process between Codex and the terminal view.
    var tmuxDefaultStyle: String {
        let effectiveTheme = resolvedTheme
        let background = tmuxHex(effectiveTheme.backgroundColor, fallback: "0e0f12")
        let foreground = tmuxHex(effectiveTheme.foregroundColor ?? NSColor.textColor, fallback: "e0e3e7")
        return "fg=#\(foreground),bg=#\(background)"
    }

    private func tmuxHex(_ color: NSColor, fallback: String) -> String {
        guard let color = color.usingColorSpace(.sRGB) else { return fallback }
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "%02x%02x%02x",
                      Int((red * 255).rounded()),
                      Int((green * 255).rounded()),
                      Int((blue * 255).rounded()))
    }

    func apply(to terminalView: LocalProcessTerminalView, fontFamily: String? = nil, fontSize: Double = 13) {
        if let fontFamily,
           let font = NSFont(name: fontFamily, size: fontSize) {
            terminalView.font = font
        } else {
            terminalView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        terminalView.disableFullRedrawOnAnyChanges = true

        let effectiveTheme = resolvedTheme
        terminalView.nativeBackgroundColor = effectiveTheme.backgroundColor
        if let foregroundColor = effectiveTheme.foregroundColor {
            terminalView.nativeForegroundColor = foregroundColor
        }
        terminalView.installColors(effectiveTheme.ansiPalette)
    }

    /// System follows the app's effective macOS appearance. Resolving this once
    /// at application time keeps the terminal ANSI palette aligned with the
    /// surrounding SwiftUI interface instead of falling back to xterm colors.
    private var resolvedTheme: TerminalTheme {
        guard self == .system else { return self }
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance(named: .aqua)!
        let match = appearance.bestMatch(from: [.aqua, .darkAqua])
        return match == .darkAqua ? .dark : .light
    }

    private var ansiPalette: [SwiftTerm.Color] {
        switch self {
        case .system:
            return Self.xtermPalette
        case .dark:
            return [
                Self.color(0x1f, 0x23, 0x28),
                Self.color(0xff, 0x6b, 0x6b),
                Self.color(0x51, 0xcf, 0x66),
                Self.color(0xff, 0xd4, 0x3b),
                Self.color(0x4d, 0xab, 0xf7),
                Self.color(0xda, 0x77, 0xf2),
                Self.color(0x22, 0xb8, 0xcf),
                Self.color(0xde, 0xe2, 0xe6),
                Self.color(0x86, 0x8e, 0x96),
                Self.color(0xff, 0x87, 0x87),
                Self.color(0x69, 0xdb, 0x7c),
                Self.color(0xff, 0xe0, 0x66),
                Self.color(0x74, 0xc0, 0xfc),
                Self.color(0xe5, 0x99, 0xf7),
                Self.color(0x3b, 0xd9, 0xdb),
                Self.color(0xf8, 0xf9, 0xfa)
            ]
        case .light:
            return [
                Self.color(0x1f, 0x29, 0x37),
                Self.color(0xb9, 0x1c, 0x1c),
                Self.color(0x16, 0x65, 0x34),
                Self.color(0x85, 0x4d, 0x0e),
                Self.color(0x1d, 0x4e, 0xd8),
                Self.color(0x7e, 0x22, 0xce),
                Self.color(0x0f, 0x76, 0x6e),
                Self.color(0x4b, 0x55, 0x63),
                Self.color(0x37, 0x41, 0x51),
                Self.color(0x99, 0x1b, 0x1b),
                Self.color(0x14, 0x53, 0x2d),
                Self.color(0x71, 0x3f, 0x12),
                Self.color(0x1e, 0x40, 0xaf),
                Self.color(0x6b, 0x21, 0xa8),
                Self.color(0x11, 0x5e, 0x59),
                Self.color(0x1f, 0x29, 0x37)
            ]
        }
    }

    private static var xtermPalette: [SwiftTerm.Color] {
        [
            color(0x00, 0x00, 0x00),
            color(0xcd, 0x00, 0x00),
            color(0x00, 0xcd, 0x00),
            color(0xcd, 0xcd, 0x00),
            color(0x00, 0x00, 0xee),
            color(0xcd, 0x00, 0xcd),
            color(0x00, 0xcd, 0xcd),
            color(0xe5, 0xe5, 0xe5),
            color(0x7f, 0x7f, 0x7f),
            color(0xff, 0x00, 0x00),
            color(0x00, 0xff, 0x00),
            color(0xff, 0xff, 0x00),
            color(0x5c, 0x5c, 0xff),
            color(0xff, 0x00, 0xff),
            color(0x00, 0xff, 0xff),
            color(0xff, 0xff, 0xff)
        ]
    }

    private static func color(_ red: UInt16, _ green: UInt16, _ blue: UInt16) -> SwiftTerm.Color {
        SwiftTerm.Color(red: red * 257, green: green * 257, blue: blue * 257)
    }
}
