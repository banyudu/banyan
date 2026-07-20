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
            }
        }
    }
    private(set) var changedAt: DispatchTime?

    private var forwardSubscription: AnyCancellable?
    private var isSyncing = false

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
