import SwiftUI

private struct SessionSidebarRevealRequest: Equatable {
    let selectedSessionID: String?
    let sessionIDs: [String]
}

private struct SessionSidebarReveal: ViewModifier {
    @ObservedObject var selection: SessionSelection
    let sessionIDs: [String]
    let proxy: ScrollViewProxy
    @State private var geometry = SessionSidebarGeometry()
    @State private var revealedSessionID: String?

    func body(content: Content) -> some View {
        let request = SessionSidebarRevealRequest(
            selectedSessionID: selection.selectedSessionID, sessionIDs: sessionIDs
        )
        content
            .onReceive(selection.$selectedSessionID.removeDuplicates()) { _ in
                revealedSessionID = nil
            }
            .onPreferenceChange(SessionSidebarGeometryKey.self) { geometry in
                self.geometry = geometry
                if let id = selection.selectedSessionID, fullyVisible(id, in: geometry) {
                    revealedSessionID = id
                }
            }
            .task(id: request) { @MainActor in
                guard let id = request.selectedSessionID, request.sessionIDs.contains(id),
                      revealedSessionID != id else { return }
                // Selection can arrive before List has inserted its new row. Wait
                // for the view update, and retry whenever the rendered IDs change.
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
                guard !Task.isCancelled, selection.selectedSessionID == id else { return }
                if fullyVisible(id, in: geometry) {
                    revealedSessionID = id
                    return
                }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    // No anchor moves only as far as needed and leaves visible
                    // selections in place, without animating intermediate rows.
                    proxy.scrollTo(id)
                }
            }
    }

    private func fullyVisible(_ id: String, in geometry: SessionSidebarGeometry) -> Bool {
        guard let frame = geometry.rows[id], geometry.viewportSize.height > 0 else { return false }
        return frame.minY >= 0 && frame.maxY <= geometry.viewportSize.height
    }
}

extension View {
    func sessionSidebarReveal(selection: SessionSelection, sessionIDs: [String], proxy: ScrollViewProxy) -> some View {
        modifier(SessionSidebarReveal(selection: selection, sessionIDs: sessionIDs, proxy: proxy))
    }
}
