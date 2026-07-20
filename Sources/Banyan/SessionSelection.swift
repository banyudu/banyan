import AppKit
import BanyanCore
import Combine
import Foundation

/// Lightweight selection state decoupled from ``SessionStore`` so the sidebar
/// highlight and terminal switcher can react to clicks without waiting for the
/// store's heavy view-tree re-evaluation.
@MainActor
final class SessionSelection: ObservableObject {
    @Published var selectedSessionID: String? {
        didSet {
            if oldValue != selectedSessionID {
                changedAt = .now()
                if let clickAt = pendingClickAt {
                    PerformanceTelemetry.shared.recordDuration(
                        "selection.click_to_didset",
                        durationMS: PerformanceTelemetry.elapsedMS(since: clickAt),
                        sessionID: selectedSessionID
                    )
                    pendingClickAt = nil
                }
            }
        }
    }
    private(set) var changedAt: DispatchTime?
    /// Set by an NSEvent monitor the moment a mouse click lands in the sidebar.
    var pendingClickAt: DispatchTime?

    private var forwardSubscription: AnyCancellable?
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
    /// - UI clicks update selection first (fast), then store (deferred).
    /// - Programmatic changes (keyboard shortcuts) update store first, then selection (sync).
    func bind(to store: SessionStore) {
        forwardSubscription = $selectedSessionID
            .removeDuplicates()
            .sink { [weak store, weak self] newID in
                guard let self, let store, !self.isSyncing else { return }
                guard store.selectedSessionID != newID else { return }
                DispatchQueue.main.async {
                    store.selectedSessionID = newID
                }
            }
    }

    /// Called from ``SessionStore/selectedSessionID``'s `didSet` to keep
    /// the selection in sync when the store changes programmatically.
    func syncFromStore(_ newID: String?) {
        guard selectedSessionID != newID else { return }
        isSyncing = true
        selectedSessionID = newID
        isSyncing = false
    }
}
