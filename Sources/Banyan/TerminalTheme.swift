import AppKit
import SwiftTerm

enum TerminalTheme: String, CaseIterable, Identifiable {
    case system
    case dark
    case light

    var id: String { rawValue }

    var label: String {
        rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }

    func apply(to terminalView: LocalProcessTerminalView) {
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
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
        }
    }
}
