import AppKit
import SwiftTerm

enum TerminalTheme: String, CaseIterable, Identifiable {
    case system
    case dark
    case light
    case solarizedDark
    case solarizedLight
    case dracula

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        case .solarizedDark: return "Solarized Dark"
        case .solarizedLight: return "Solarized Light"
        case .dracula: return "Dracula"
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
        case .dark:
            terminalView.nativeBackgroundColor = NSColor(red: 0.055, green: 0.060, blue: 0.070, alpha: 1)
            terminalView.nativeForegroundColor = NSColor(red: 0.870, green: 0.885, blue: 0.900, alpha: 1)
        case .light:
            terminalView.nativeBackgroundColor = NSColor(red: 0.980, green: 0.980, blue: 0.960, alpha: 1)
            terminalView.nativeForegroundColor = NSColor(red: 0.090, green: 0.095, blue: 0.110, alpha: 1)
        case .solarizedDark:
            terminalView.nativeBackgroundColor = NSColor(red: 0.000, green: 0.169, blue: 0.212, alpha: 1)
            terminalView.nativeForegroundColor = NSColor(red: 0.514, green: 0.580, blue: 0.588, alpha: 1)
        case .solarizedLight:
            terminalView.nativeBackgroundColor = NSColor(red: 0.992, green: 0.965, blue: 0.890, alpha: 1)
            terminalView.nativeForegroundColor = NSColor(red: 0.396, green: 0.482, blue: 0.514, alpha: 1)
        case .dracula:
            terminalView.nativeBackgroundColor = NSColor(red: 0.157, green: 0.165, blue: 0.212, alpha: 1)
            terminalView.nativeForegroundColor = NSColor(red: 0.973, green: 0.973, blue: 0.949, alpha: 1)
        }
    }
}
