import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    func openScratchTerminal() {
        if let window = scratchWindow, scratchSession != nil {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            requestScratchTerminalFocus()
            return
        }

        let cwd = selectedSession?.cwd ?? homeDirectory
        let id = uniqueID("scratch", avoidingLiveTmuxSessions: true)
        let session = TerminalSession(
            id: id,
            tmuxSessionName: SessionIdentityPolicy.sessionName(for: id),
            title: "Scratch",
            isTitlePinned: true,
            cwd: WorkingDirectoryPolicy.resolve(
                proposedDirectory: cwd,
                currentDirectory: currentDirectory,
                homeDirectory: homeDirectory
            ),
            command: "",
            tone: .neutral,
            theme: terminalTheme,
            fontFamily: terminalFontFamily,
            fontSize: terminalFontSize,
            tmuxBackend: sessionBackend,
            telemetry: telemetry,
            host: host,
            githubReferenceCache: githubReferenceCache
        )
        attachScratch(session)
        scratchSession = session

        let rootView = ScratchTerminalWindow(session: session)
            .environmentObject(self)
            .buttonStyle(.banyanDefault)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 500),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.identifier = Self.scratchWindowIdentifier
        WindowRestorationPolicy.configure(window)
        window.title = scratchWindowTitle(for: session)
        window.contentViewController = NSHostingController(rootView: rootView)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenAuxiliary]

        let delegate = ScratchTerminalWindowDelegate { [weak self] in
            Task { @MainActor in
                self?.scratchTerminalWindowWillClose()
            }
        }
        window.delegate = delegate
        scratchWindow = window
        scratchWindowDelegate = delegate

        positionScratchWindow(window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        requestScratchTerminalFocus()
    }

    func handleCloseCommand(in window: NSWindow?) {
        if isScratchTerminalWindow(window) {
            closeScratchTerminal()
            return
        }
        requestCloseSelectedSession()
    }

    func closeScratchTerminal() {
        closeScratchTerminal(closeWindow: true, killBackingSession: true)
    }

    private func scratchTerminalWindowWillClose() {
        closeScratchTerminal(closeWindow: false, killBackingSession: true)
    }

    private func attachScratch(_ session: TerminalSession) {
        session.onDidChange = { [weak self, weak session] in
            Task { @MainActor in
                guard let self, let session, self.scratchSession === session else { return }
                self.scratchWindow?.title = self.scratchWindowTitle(for: session)
            }
        }
        let telemetry = self.telemetry
        session.onOutput = { [weak session, telemetry] _ in
            guard let session else { return }
            telemetry.noteSessionFirstOutput(sessionID: session.id)
        }
        session.onStatusSignal = nil
        session.onProcessExit = { [weak self, weak session] _ in
            guard let self, let session, self.scratchSession === session else { return }
            if self.tmuxBackend.hasSession(named: session.tmuxSessionName) {
                session.detachTerminalClient()
            } else {
                self.closeScratchTerminal(closeWindow: true, killBackingSession: false)
            }
        }
    }

    private func closeScratchTerminal(closeWindow: Bool, killBackingSession: Bool) {
        guard !isClosingScratchTerminal else { return }
        guard scratchSession != nil || scratchWindow != nil else { return }
        isClosingScratchTerminal = true

        let session = scratchSession
        let window = scratchWindow
        scratchSession = nil
        scratchWindow = nil
        scratchWindowDelegate = nil

        if killBackingSession {
            session?.killBackingSession()
        } else {
            session?.terminate(markClosed: true)
        }

        if closeWindow {
            window?.delegate = nil
            window?.close()
        }

        isClosingScratchTerminal = false
    }

    private func requestScratchTerminalFocus() {
        scratchTerminalFocusRequestID = UUID()
    }

    func requestTerminalFocus() {
        terminalFocusRequestID = UUID()
    }

    func focusSelectedTerminal() {
        requestTerminalFocus()
    }

    func applyAppearance() {
        sessions.forEach {
            $0.apply(theme: terminalTheme, fontFamily: terminalFontFamily, fontSize: terminalFontSize)
        }
        scratchSession?.apply(theme: terminalTheme, fontFamily: terminalFontFamily, fontSize: terminalFontSize)
    }

    /// Reads the resolved preference rather than the published one so an
    /// environment pin keeps winning over the picker.
    func applyTerminalRenderer() {
        let renderer = TerminalRendererPreference.resolvedDefault
        sessions.forEach { $0.apply(renderer: renderer) }
        scratchSession?.apply(renderer: renderer)
    }

    func refreshTerminalAppearance() {
        sessions.forEach {
            $0.apply(theme: terminalTheme, fontFamily: terminalFontFamily, fontSize: terminalFontSize, force: true)
        }
        scratchSession?.apply(theme: terminalTheme, fontFamily: terminalFontFamily, fontSize: terminalFontSize, force: true)
    }

    private func isScratchTerminalWindow(_ window: NSWindow?) -> Bool {
        window?.identifier == Self.scratchWindowIdentifier
    }

    private func scratchWindowTitle(for session: BanyanSession) -> String {
        "Scratch - \(PathDisplayName.make(path: session.cwd, homeDirectory: homeDirectory))"
    }

    private func positionScratchWindow(_ window: NSWindow) {
        let fallbackScreen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let anchorWindow = NSApp.keyWindow ?? NSApp.mainWindow
        let anchorFrame = anchorWindow?.frame ?? fallbackScreen
        let visibleFrame = anchorWindow?.screen?.visibleFrame ?? fallbackScreen

        window.setFrame(
            ScratchWindowGeometry.frame(anchorFrame: anchorFrame, visibleFrame: visibleFrame),
            display: false
        )
    }
}
