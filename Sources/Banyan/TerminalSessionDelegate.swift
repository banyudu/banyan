import AppKit
import SwiftTerm

final class TerminalSessionDelegate: NSObject, LocalProcessTerminalViewDelegate {
    let sessionID: String
    var onTitle: ((String) -> Void)?
    var onDirectoryChange: ((String?) -> Void)?
    var onTerminate: ((Int32?) -> Void)?
    var onOpenLink: ((String) -> Void)?
    var isCurrentSource: ((TerminalView) -> Bool)?

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        DispatchQueue.main.async { [weak self] in
            guard self?.isCurrentSource?(source) != false else { return }
            self?.onTitle?(title)
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        DispatchQueue.main.async { [weak self] in
            guard self?.isCurrentSource?(source) != false else { return }
            self?.onDirectoryChange?(directory)
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { [weak self] in
            guard self?.isCurrentSource?(source) != false else { return }
            self?.onTerminate?(exitCode)
        }
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
        onOpenLink?(link)
    }
}
