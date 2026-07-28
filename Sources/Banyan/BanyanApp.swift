import AppKit
import SwiftUI

@main
struct BanyanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SessionStore()

    var body: some Scene {
        WindowGroup {
            ContentView(selection: store.selection)
                .environmentObject(store)
                .buttonStyle(.banyanDefault)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    CommandWTerminalCloseMonitor.shared.action = { window in
                        store.handleCloseCommand(in: window)
                    }
                    CommandWTerminalCloseMonitor.shared.start()

                    JumpOverlayMonitor.shared.onJump = { [weak store] index in
                        store?.selectSession(shortcutIndex: index) ?? false
                    }
                    JumpOverlayMonitor.shared.onNext = { [weak store] in
                        guard let store else { return }
                        if store.sidebarMode == .linear {
                            store.selectNextLinearIssue()
                        } else {
                            store.selectNextSession()
                        }
                    }
                    JumpOverlayMonitor.shared.onPrevious = { [weak store] in
                        guard let store else { return }
                        if store.sidebarMode == .linear {
                            store.selectPreviousLinearIssue()
                        } else {
                            store.selectPreviousSession()
                        }
                    }
                    JumpOverlayMonitor.shared.onHandoff = { [weak store] in
                        store?.handleHandoffShortcut()
                        return true
                    }
                    JumpOverlayMonitor.shared.start()
                    store.selection.startClickMonitor()

                    SessionRenameShortcutMonitor.shared.action = { [weak store] in
                        guard let store,
                              store.sidebarMode == .sessions,
                              store.selectedSession != nil else {
                            return false
                        }
                        store.selection.requestRenameSelectedSession()
                        return true
                    }
                    SessionRenameShortcutMonitor.shared.start()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    store.spawnSiblingSession()
                }
                .keyboardShortcut("n")

                Button("New Terminal") {
                    store.spawnTerminalSiblingSession()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
            CommandGroup(after: .pasteboard) {
                Button("Find") {
                    if store.sidebarMode == .linear {
                        store.requestLinearFilterFocus()
                    } else {
                        store.showFindInSelectedSession()
                    }
                }
                .keyboardShortcut("f")
                .disabled(store.sidebarMode == .linear
                    ? false
                    : store.selectedSession?.isImportedHistory != false)
            }
            CommandMenu("Session") {
                Button("Rename Session") {
                    store.selection.requestRenameSelectedSession()
                }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(0xF705)!)))
                .disabled(store.sidebarMode != .sessions || store.selectedSession == nil)
            }
            CommandMenu("View") {
                Button("Show Command Palette") {
                    store.requestCommandPalette()
                }
                .keyboardShortcut("p")
            }
            CommandMenu("Terminal") {
                Button("Close Current Terminal") {
                    store.handleCloseCommand(in: NSApp.keyWindow)
                }
                .keyboardShortcut("w")
                .disabled(store.selectedSession == nil && !store.hasScratchTerminal)

                Divider()

                Button("Open Scratch Terminal") {
                    store.openScratchTerminal()
                }
                .keyboardShortcut("d")

                Divider()

                Button("Preview GitHub Pull Request") {
                    store.showSelectedPullRequestPreview()
                }
                .keyboardShortcut("g")
                .disabled(store.selectedSession?.status == .closed || store.selectedSession == nil)

                Button("Open Linear Issue") {
                    store.openSelectedLinearIssue()
                }
                .keyboardShortcut("l")
                .disabled(store.sidebarMode == .linear
                    ? store.selectedLinearListIssueURL == nil
                    : store.selectedLinearIssueURL == nil)

                Button("Show Linear Issues") {
                    store.sidebarMode = .linear
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Button("Show Sessions") {
                    store.sidebarMode = .sessions
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Start Selected Linear Issue") {
                    store.startSelectedLinearListIssueSession()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(store.sidebarMode != .linear || store.selectedLinearListIssueID == nil)

                Button("Refresh Linear Issues") {
                    store.refreshLinearIssueList()
                }
                .keyboardShortcut("r")
                .disabled(store.sidebarMode != .linear || store.isLinearIssueListRefreshing)

                Divider()

                Button("Next Terminal") {
                    store.selectNextSession()
                }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(store.sidebarSessions.count < 2)

                Button("Previous Terminal") {
                    store.selectPreviousSession()
                }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(store.sidebarSessions.count < 2)

                Button("Next Workable Terminal") {
                    store.selectNextWorkableSession()
                }
                .disabled(!store.hasWorkableSession)

                Divider()

                ForEach(Array(store.sidebarSessions.prefix(10).enumerated()), id: \.element.id) { index, item in
                    let shortcutIndex = index + 1
                    let shortcutCharacter = index == 9 ? "0" : String(shortcutIndex)
                    Button("Switch to Terminal \(shortcutIndex): \(item.session.displayTitle)") {
                        store.selectSession(shortcutIndex: shortcutIndex)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(shortcutCharacter)), modifiers: .command)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            Self.disableDefaultCloseWindowShortcut()
        }
        Task { @MainActor in
            AttentionNotifier.shared.requestAuthorization()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Self.disableDefaultCloseWindowShortcut()
    }

    private static func disableDefaultCloseWindowShortcut() {
        NSApp.mainMenu?.forEachItem { item in
            guard item.action == #selector(NSWindow.performClose(_:)),
                  item.keyEquivalent.lowercased() == "w" else {
                return
            }
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        }
    }
}

private final class SessionRenameShortcutMonitor {
    static let shared = SessionRenameShortcutMonitor()

    var action: () -> Bool = { false }
    private var monitor: Any?

    private init() {}

    deinit {
        stop()
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.isF2(event), self?.action() == true else {
                return event
            }
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private static func isF2(_ event: NSEvent) -> Bool {
        guard !event.isARepeat, event.keyCode == 120 else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return !modifiers.contains(.command)
            && !modifiers.contains(.option)
            && !modifiers.contains(.control)
            && !modifiers.contains(.shift)
    }
}

private extension NSMenu {
    func forEachItem(_ body: (NSMenuItem) -> Void) {
        for item in items {
            body(item)
            item.submenu?.forEachItem(body)
        }
    }
}

private final class CommandWTerminalCloseMonitor {
    static let shared = CommandWTerminalCloseMonitor()

    var action: (NSWindow?) -> Void = { _ in }
    private var monitor: Any?

    private init() {}

    deinit {
        stop()
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard Self.matchesPlainCommandW(event) else {
                return event
            }
            self?.action(event.window ?? NSApp.keyWindow)
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private static func matchesPlainCommandW(_ event: NSEvent) -> Bool {
        guard !event.isARepeat else { return false }
        guard event.charactersIgnoringModifiers?.lowercased() == "w" else { return false }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return modifiers.contains(.command)
            && !modifiers.contains(.option)
            && !modifiers.contains(.control)
            && !modifiers.contains(.shift)
    }
}
