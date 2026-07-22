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
                        store?.selectNextSession()
                    }
                    JumpOverlayMonitor.shared.onPrevious = { [weak store] in
                        store?.selectPreviousSession()
                    }
                    JumpOverlayMonitor.shared.onHandoff = { [weak store] in
                        store?.handleHandoffShortcut()
                        return true
                    }
                    JumpOverlayMonitor.shared.start()
                    store.selection.startClickMonitor()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Terminal") {
                    store.spawnSiblingSession()
                }
                .keyboardShortcut("n")

                Button("New Child Terminal...") {
                    store.showChildSessionSheet()
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(store.selectedSession == nil)
            }
            CommandGroup(after: .pasteboard) {
                Button("Find") {
                    store.showFindInSelectedSession()
                }
                .keyboardShortcut("f")
                .disabled(store.selectedSession?.isImportedHistory != false)
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
                .disabled(store.selectedLinearIssueURL == nil)

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
                .keyboardShortcut("p")
                .disabled(!store.hasWorkableSession)

                Divider()

                ForEach(Array(store.sidebarSessions.prefix(9).enumerated()), id: \.element.id) { index, item in
                    Button("Switch to Terminal \(index + 1): \(item.session.displayTitle)") {
                        store.selectSession(shortcutIndex: index + 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
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
