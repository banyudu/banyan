import AppKit
import BanyanCore
import Combine
import Foundation

/// Lightweight selection state decoupled from ``SessionStore`` so the sidebar
/// highlight and terminal switcher can react to clicks without waiting for the
/// store's heavy view-tree re-evaluation.
@MainActor
final class SessionSelection: ObservableObject {
    /// Changes each time the selected session should enter inline rename mode.
    /// A request ID is used so pressing F2 repeatedly still produces a distinct
    /// event even when the selected session has not changed.
    @Published private(set) var renameRequestID = UUID()

    @Published var selectedSessionID: String? {
        didSet {
            if oldValue != selectedSessionID {
                changedAt = .now()
                let clickAt = pendingClickAt.flatMap { timestamp in
                    PerformanceTelemetry.elapsedMS(since: timestamp) <= 1_000 ? timestamp : nil
                }
                if let clickAt, let telemetry = store?.telemetry {
                    telemetry.recordDuration(
                        "selection.click_to_didset",
                        durationMS: PerformanceTelemetry.elapsedMS(since: clickAt),
                        sessionID: selectedSessionID
                    )
                }
                let forwardToStore = isSyncing ? nil : storeSelectionForwarder(for: selectedSessionID)
                let waitsForProjectLayout = switcher?.switchImmediately(
                    to: selectedSessionID,
                    selectionChangedAt: changedAt,
                    clickAt: clickAt,
                    afterPaint: forwardToStore
                ) ?? false
                if switcher == nil {
                    forwardToStore?()
                } else if waitsForProjectLayout {
                    // The selected context controls whether the right issue panel
                    // reserves terminal width. Commit it before revealing a
                    // cross-project terminal so tmux receives its final geometry
                    // while the target is still hidden.
                    forwardToStore?()
                }
                pendingClickAt = nil
            }
        }
    }
    private(set) var changedAt: DispatchTime?
    /// Set by an NSEvent monitor the moment a mouse click lands in the sidebar.
    var pendingClickAt: DispatchTime?
    /// Direct reference to bypass SwiftUI's view update pipeline for visibility toggles.
    weak var switcher: TerminalSwitcherContainer?

    private weak var store: SessionStore?
    private var isSyncing = false

    private var clickMonitor: Any?

    /// Start monitoring mouse clicks to timestamp the moment a sidebar click lands.
    func startClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.pendingClickAt = .now()
            return event
        }
    }

    /// Wire bidirectional sync: selection ↔ store.
    /// - Sidebar and navigation changes update selection first, then store after paint.
    /// - Lifecycle changes update the store first, then selection synchronously.
    func bind(to store: SessionStore) {
        self.store = store
    }

    /// Called from ``SessionStore/selectedSessionID``'s `didSet` to keep
    /// the selection in sync when the store changes programmatically.
    func syncFromStore(_ newID: String?) {
        guard selectedSessionID != newID else { return }
        isSyncing = true
        selectedSessionID = newID
        isSyncing = false
    }

    func requestRenameSelectedSession() {
        guard selectedSessionID != nil else { return }
        renameRequestID = UUID()
    }

    private func storeSelectionForwarder(for newID: String?) -> () -> Void {
        { [weak self, weak store] in
            guard let self, let store, self.selectedSessionID == newID else { return }
            guard store.selectedSessionID != newID else { return }
            store.selectedSessionID = newID
        }
    }
}
