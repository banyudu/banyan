import AppKit
import Testing
@testable import Banyan

@Test @MainActor func snapshotPolicyKeepsWindowRestorable() {
    let window = NSWindow(
        contentRect: .zero,
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )

    #expect(window.isRestorable)
    WindowRestorationPolicy.configure(window)
    #expect(window.isRestorable)
}
