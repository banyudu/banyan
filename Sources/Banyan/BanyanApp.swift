import SwiftUI

@main
struct BanyanApp: App {
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
                    store.spawn(title: "Shell", cwd: NSHomeDirectory())
                }
                .keyboardShortcut("n")
            }
        }
    }
}
