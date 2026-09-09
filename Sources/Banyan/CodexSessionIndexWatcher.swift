import Foundation

/// Watches Codex's session index and reports when it changes.
///
/// Codex names a thread a few seconds after the first prompt, by appending a
/// second row to `~/.codex/session_index.jsonl`. Nothing in a Banyan session's
/// own lifecycle marks that moment, so without a watch the new name would not
/// surface until the next history import — in practice, the next app launch.
/// A file-system source costs nothing while Codex is idle, which a repeating
/// timer would not.
@MainActor
final class CodexSessionIndexWatcher {
    private let url: URL
    private let debounce: Duration
    private let onChange: () -> Void

    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var pendingNotification: Task<Void, Never>?

    init(url: URL, debounce: Duration = .seconds(2), onChange: @escaping () -> Void) {
        self.url = url
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        source?.cancel()
    }

    /// Begins watching. A missing index means Codex has not run on this machine
    /// yet; the watch is simply not installed, and the next launch picks it up.
    func start() {
        guard source == nil else { return }
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let events = self.source?.data ?? []
            if events.contains(.delete) || events.contains(.rename) {
                // Codex replaced the file rather than appending to it. The old
                // descriptor now points at nothing, so re-arm on the new one.
                self.restart()
            } else {
                self.scheduleNotification()
            }
        }
        source.setCancelHandler { [descriptor] in
            close(descriptor)
        }

        self.descriptor = descriptor
        self.source = source
        source.resume()
    }

    func stop() {
        pendingNotification?.cancel()
        pendingNotification = nil
        source?.cancel()
        source = nil
        descriptor = -1
    }

    private func restart() {
        stop()
        start()
        scheduleNotification()
    }

    /// Codex writes the placeholder and the generated name as two separate
    /// appends seconds apart. Coalescing bursts keeps one rename from costing
    /// two history imports; the read that lands on the placeholder is a no-op
    /// because an untitled thread reports no title at all.
    private func scheduleNotification() {
        pendingNotification?.cancel()
        pendingNotification = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled, let self else { return }
            self.pendingNotification = nil
            self.onChange()
        }
    }
}
