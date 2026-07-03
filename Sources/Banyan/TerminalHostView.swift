import SwiftUI
import SwiftTerm

struct TerminalHostView: NSViewRepresentable {
    let session: BanyanSession
    let theme: TerminalTheme

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.apply(theme: theme)
        return session.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        session.apply(theme: theme)
    }
}
