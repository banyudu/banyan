import Foundation

/// Watches the files that feed the agent picker (`~/.banyan/config.yml` and
/// `~/.agents/agents.yml`, plus `~/.banyan/palette.yml` which shares the same
/// reload path) and reports when any of them may have changed.
///
/// Files may not exist yet (fresh home, registry never written), and editors
/// typically save atomically (delete + rename), so watching only the files
/// themselves misses creations. Each existing file gets a file-system source
/// for content writes, and each existing parent directory — plus the home
/// directory itself, so a newly created `~/.banyan` or `~/.agents` is noticed
/// — gets a directory source. Any event re-arms the file sources (a replaced
/// file needs a new descriptor) and schedules one debounced notification.
///
/// A file-system source costs nothing while the watched files are idle, which
/// a repeating timer would not.
@MainActor
final class LaunchConfigWatcher {
    private let homeDirectory: URL
    private let watchedFiles: [URL]
    private let debounce: Duration
    private let onChange: () -> Void

    private var fileWatchers: [(descriptor: CInt, source: DispatchSourceFileSystemObject)] = []
    private var directoryWatchers: [(descriptor: CInt, source: DispatchSourceFileSystemObject)] = []
    private var pendingNotification: Task<Void, Never>?

    init(
        homeDirectory: URL,
        watchedFiles: [URL],
        debounce: Duration = .milliseconds(500),
        onChange: @escaping () -> Void
    ) {
        self.homeDirectory = homeDirectory
        self.watchedFiles = watchedFiles
        self.debounce = debounce
        self.onChange = onChange
    }

    deinit {
        for watcher in fileWatchers + directoryWatchers {
            watcher.source.cancel()
        }
    }

    /// Begins watching. Missing files and directories are simply skipped; the
    /// home-directory source notices their creation and re-arms the rest.
    func start() {
        guard fileWatchers.isEmpty, directoryWatchers.isEmpty else { return }
        armFileWatchers()
        armDirectoryWatchers()
    }

    func stop() {
        pendingNotification?.cancel()
        pendingNotification = nil
        for watcher in fileWatchers + directoryWatchers {
            watcher.source.cancel()
        }
        fileWatchers = []
        directoryWatchers = []
    }

    private func armFileWatchers() {
        for watcher in fileWatchers {
            watcher.source.cancel()
        }
        fileWatchers = []
        for url in watchedFiles {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .delete, .rename],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let events = source.data
                if events.contains(.delete) || events.contains(.rename) {
                    // Atomic saves replace the file rather than modifying it.
                    // The old descriptor points at nothing, so re-arm and report.
                    self.rearmFileWatchers()
                    self.scheduleNotification()
                } else {
                    self.scheduleNotification()
                }
            }
            source.setCancelHandler { [descriptor] in
                close(descriptor)
            }
            fileWatchers.append((descriptor, source))
            source.resume()
        }
    }

    private func armDirectoryWatchers() {
        for watcher in directoryWatchers {
            watcher.source.cancel()
        }
        directoryWatchers = []
        var directories = Set<URL>()
        directories.insert(homeDirectory.standardizedFileURL)
        for url in watchedFiles {
            directories.insert(url.deletingLastPathComponent().standardizedFileURL)
        }
        for directory in directories {
            let descriptor = open(directory.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let events = source.data
                if events.contains(.delete) || events.contains(.rename) {
                    // A watched directory was replaced (unlikely for home, but
                    // cheap to handle): re-arm everything from scratch.
                    self.rearmAll()
                } else {
                    // A directory entry changed: a file may have been created,
                    // deleted, or atomically replaced. Re-arm the file sources
                    // so a new file gets watched, then report.
                    self.rearmFileWatchers()
                }
                self.scheduleNotification()
            }
            source.setCancelHandler { [descriptor] in
                close(descriptor)
            }
            directoryWatchers.append((descriptor, source))
            source.resume()
        }
    }

    private func rearmFileWatchers() {
        armFileWatchers()
    }

    private func rearmAll() {
        armFileWatchers()
        armDirectoryWatchers()
    }

    /// Editors emit bursts (write, delete, rename) for a single save.
    /// Coalesce them so one save costs one reload — three small YAML reads.
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
