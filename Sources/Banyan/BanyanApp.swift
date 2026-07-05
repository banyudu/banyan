import AppKit
import SwiftUI

@main
struct BanyanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = SessionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    CommandWTerminalCloseMonitor.shared.action = {
                        store.requestCloseSelectedSession()
                    }
                    CommandWTerminalCloseMonitor.shared.start()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Terminal") {
                    store.forkSelectedSession()
                }
                .keyboardShortcut("n")
            }
            CommandMenu("Terminal") {
                Button("Close Current Terminal") {
                    store.requestCloseSelectedSession()
                }
                .keyboardShortcut("w")
                .disabled(store.selectedSession == nil)

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
        Task { @MainActor in
            AttentionNotifier.shared.requestAuthorization()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

private final class CommandWTerminalCloseMonitor {
    static let shared = CommandWTerminalCloseMonitor()

    var action: () -> Void = {}
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
            self?.action()
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
