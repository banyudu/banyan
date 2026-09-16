import Foundation

/// Which renderer a terminal view paints with.
///
/// SwiftTerm ships an experimental Metal path (CoreText glyph atlas + GPU
/// quads) that is off by default. This preference exists so it can be A/B'd
/// against CoreGraphics on a real workload and reverted in one click, rather
/// than being wired in permanently before the measurements justify it.
enum TerminalRendererPreference: String, CaseIterable, Identifiable {
    case coreGraphics
    case metal

    static let defaultsKey = "terminalRenderer"
    /// Pins an arm for a benchmark run without touching the user's settings.
    static let environmentKey = "BANYAN_TERMINAL_RENDERER"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .coreGraphics: return "CoreGraphics"
        case .metal: return "Metal (experimental)"
        }
    }

    /// Recorded in the `terminal.draw` detail so one performance report can
    /// separate samples produced by each renderer.
    var telemetryName: String {
        switch self {
        case .coreGraphics: return "cg"
        case .metal: return "metal"
        }
    }

    static func fromPersistedRawValue(_ raw: String) -> TerminalRendererPreference? {
        switch raw.lowercased() {
        case "metal", "gpu":
            return .metal
        case "coregraphics", "core-graphics", "cg", "cpu":
            return .coreGraphics
        default:
            return nil
        }
    }

    /// The environment wins over the stored preference so a benchmark arm, or a
    /// user recovering from a bad GPU driver, can force a renderer at launch.
    static func resolve(
        environment: [String: String],
        storedRawValue: String?
    ) -> TerminalRendererPreference {
        if let raw = environment[environmentKey], let pinned = fromPersistedRawValue(raw) {
            return pinned
        }
        if let storedRawValue, let stored = fromPersistedRawValue(storedRawValue) {
            return stored
        }
        return .coreGraphics
    }

    static func isPinnedByEnvironment(_ environment: [String: String]) -> Bool {
        guard let raw = environment[environmentKey] else { return false }
        return fromPersistedRawValue(raw) != nil
    }

    static var resolvedDefault: TerminalRendererPreference {
        resolve(
            environment: ProcessInfo.processInfo.environment,
            storedRawValue: UserDefaults.standard.string(forKey: defaultsKey)
        )
    }
}
