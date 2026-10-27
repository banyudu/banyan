import AppKit
import BanyanCore
import Combine
import SwiftUI

/// One map per window, shared by its badges, keyboard dispatch, menu and palette.
/// Destinations are session IDs so an insert/removal cannot retarget a held chord.
@MainActor
final class SessionJumpShortcuts: ObservableObject {
    @Published private(set) var sessionIDs: [String] = []
    private var allSessionIDs: [String] = []
    private var visibleSessionIDs: [String] = []
    private var rollingEnabled = true
    private var commandHeld = false
    private let commandModifierSubject = CurrentValueSubject<Bool, Never>(false)
    var commandModifierChanges: AnyPublisher<Bool, Never> {
        commandModifierSubject.eraseToAnyPublisher()
    }

    private static let windows = NSMapTable<NSWindow, SessionJumpShortcuts>(
        keyOptions: .weakMemory, valueOptions: .weakMemory
    )

    static func forWindow(_ window: NSWindow?) -> SessionJumpShortcuts? {
        guard let window else { return nil }
        return windows.object(forKey: window) ?? forWindow(window.sheetParent)
    }

    func register(window: NSWindow) {
        guard Self.windows.object(forKey: window) !== self else { return }
        Self.windows.setObject(self, forKey: window)
        setCommandHeld(NSEvent.modifierFlags.contains(.command))
    }

    static func setCommandHeldInAllWindows(_ held: Bool) {
        for shortcuts in windows.objectEnumerator()?.allObjects as? [SessionJumpShortcuts] ?? [] {
            shortcuts.setCommandHeld(held)
        }
    }

    func updateSessionIDs(_ ids: [String]) {
        allSessionIDs = ids
        refresh()
    }

    func setRollingEnabled(_ enabled: Bool) {
        rollingEnabled = enabled
        refresh()
    }

    func updateVisibleSessionIDs(_ ids: [String]) {
        // A status-driven reorder of the same visible rows keeps their keys.
        // Scrolling a different set into view assigns from the top again.
        guard Set(ids) != Set(visibleSessionIDs) else { return }
        visibleSessionIDs = ids
        refresh()
    }

    func setCommandHeld(_ held: Bool) {
        guard held != commandHeld else { return }
        commandHeld = held
        commandModifierSubject.send(held)
        if !held { refresh() }
    }

    func sessionID(for oneBasedIndex: Int) -> String? {
        SessionSelectionNavigator.directID(in: sessionIDs, oneBasedIndex: oneBasedIndex)
    }

    func index(for sessionID: String) -> Int? {
        sessionIDs.firstIndex(of: sessionID).map { $0 + 1 }
    }

    func label(for sessionID: String) -> String {
        index(for: sessionID).flatMap(JumpOverlayMonitor.jumpLabel) ?? ""
    }

    func shortcutDisplay(for sessionID: String) -> String? {
        index(for: sessionID).flatMap(JumpOverlayMonitor.shortcutDisplay)
    }

    /// One viewport of session rows. Paging uses this so the target lands in
    /// the next screenful rather than at a fixed, arbitrary row count.
    var pageStride: Int {
        max(1, visibleSessionIDs.count)
    }

    private func refresh() {
        guard !commandHeld else { return }
        let available = Set(allSessionIDs)
        let candidates = rollingEnabled ? visibleSessionIDs.filter { available.contains($0) } : allSessionIDs
        let updated = Array(candidates.prefix(JumpOverlayMonitor.maxSessionSlots))
        if updated != sessionIDs { sessionIDs = updated }
    }
}

/// Limit viewport-driven publications to the UI that displays shortcut labels.
/// The containing window should retain the map without observing it.
struct SessionShortcutMapObserver<Content: View>: View {
    @ObservedObject var shortcuts: SessionJumpShortcuts
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
    }
}

/// Row lifetime is not visibility: List may prefetch offscreen rows. Measure
/// intersections with its viewport instead, using macOS 14 SwiftUI geometry.
struct SessionSidebarGeometry: Equatable {
    var viewportSize: CGSize = .zero
    var rows: [String: CGRect] = [:]

    var visibleSessionIDs: [String] {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        return rows.filter { _, frame in
            let intersection = frame.intersection(viewport)
            return !intersection.isNull && intersection.width > 0 && intersection.height > 0
        }.sorted { lhs, rhs in
            if lhs.value.minY != rhs.value.minY { return lhs.value.minY < rhs.value.minY }
            return lhs.key < rhs.key
        }.map(\.key)
    }
}

struct SessionSidebarGeometryKey: PreferenceKey {
    static let defaultValue = SessionSidebarGeometry()
    static let coordinateSpace = "session-jump-viewport"

    static func reduce(value: inout SessionSidebarGeometry, nextValue: () -> SessionSidebarGeometry) {
        let next = nextValue()
        if next.viewportSize != .zero { value.viewportSize = next.viewportSize }
        value.rows.merge(next.rows, uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func sessionJumpShortcutRow(id: String) -> some View {
        background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: SessionSidebarGeometryKey.self,
                    value: SessionSidebarGeometry(rows: [
                        id: geometry.frame(in: .named(SessionSidebarGeometryKey.coordinateSpace))
                    ])
                )
            }
        }
    }

    func sessionJumpShortcutViewport(shortcuts: SessionJumpShortcuts, sessionIDs: [String]) -> some View {
        coordinateSpace(name: SessionSidebarGeometryKey.coordinateSpace)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: SessionSidebarGeometryKey.self,
                        value: SessionSidebarGeometry(viewportSize: geometry.size)
                    )
                }
            }
            .onPreferenceChange(SessionSidebarGeometryKey.self) { geometry in
                shortcuts.updateVisibleSessionIDs(geometry.visibleSessionIDs)
            }
            .onChange(of: sessionIDs, initial: true) { _, ids in
                shortcuts.updateSessionIDs(ids)
            }
    }
}
