import AppKit

/// Keeps ordinary window restoration while suppressing AppKit's image snapshots.
enum WindowRestorationPolicy {
    static func configure(_ window: NSWindow) {
        window.disableSnapshotRestoration()
    }
}
