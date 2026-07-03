import SwiftUI
import SwiftTerm

struct TerminalHostView: NSViewRepresentable {
    let session: BanyanSession
    let theme: TerminalTheme
    let fontFamily: String
    let fontSize: Double

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        session.apply(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
        return session.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        session.apply(theme: theme, fontFamily: fontFamily, fontSize: fontSize)
    }
}
