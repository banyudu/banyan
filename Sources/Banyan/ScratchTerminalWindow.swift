import AppKit
import SwiftUI

struct ScratchTerminalWindow: View {
    @EnvironmentObject private var store: SessionStore
    @ObservedObject var session: BanyanSession

    var body: some View {
        TerminalHostView(
            session: session,
            theme: store.terminalTheme,
            fontFamily: store.terminalFontFamily,
            fontSize: store.terminalFontSize,
            focusRequestID: store.scratchTerminalFocusRequestID
        )
        .ignoresSafeArea()
        .frame(minWidth: 520, minHeight: 320)
    }
}

final class ScratchTerminalWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
