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
        true
    }
}
