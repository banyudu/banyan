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
            CommandGroup(after: .newItem) {
                Button("New Session") {
                    store.forkSelectedSession()
                }
                .keyboardShortcut("n")
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
