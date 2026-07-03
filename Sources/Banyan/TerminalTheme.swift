import AppKit
import SwiftUI
import SwiftTerm

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
            return NSColor(red: 0.980, green: 0.980, blue: 0.960, alpha: 1)
        }
    }

    var foregroundColor: NSColor? {
        switch self {
        case .system:
            return nil
        case .dark:
            return NSColor(red: 0.870, green: 0.885, blue: 0.900, alpha: 1)
        case .light:
            return NSColor(red: 0.090, green: 0.095, blue: 0.110, alpha: 1)
        }
    }

    func apply(to terminalView: LocalProcessTerminalView, fontFamily: String? = nil, fontSize: Double = 13) {
        if let fontFamily,
           let font = NSFont(name: fontFamily, size: fontSize) {
            terminalView.font = font
        } else {
            terminalView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        terminalView.disableFullRedrawOnAnyChanges = true

        switch self {
        case .system:
            terminalView.configureNativeColors()
            terminalView.installColors(Self.xtermPalette)
        default:
            terminalView.nativeBackgroundColor = backgroundColor
            if let foregroundColor {
                terminalView.nativeForegroundColor = foregroundColor
            }
            terminalView.installColors(ansiPalette)
        }
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
                Self.color(0x24, 0x29, 0x2f),
                Self.color(0xcf, 0x22, 0x2e),
                Self.color(0x1a, 0x7f, 0x37),
                Self.color(0x9a, 0x67, 0x00),
                Self.color(0x09, 0x6a, 0xda),
                Self.color(0x82, 0x50, 0xdf),
                Self.color(0x1b, 0x7c, 0x83),
                Self.color(0x6e, 0x77, 0x80),
                Self.color(0x57, 0x60, 0x6a),
                Self.color(0xa4, 0x0e, 0x26),
                Self.color(0x11, 0x69, 0x29),
                Self.color(0x7d, 0x4e, 0x00),
                Self.color(0x05, 0x56, 0xb3),
                Self.color(0x66, 0x37, 0xba),
                Self.color(0x0e, 0x6e, 0x75),
                Self.color(0x24, 0x29, 0x2f)
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
