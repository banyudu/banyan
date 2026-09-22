import BanyanCore
import Foundation

/// One execution of a user-configured palette command, in the shape the sidebar
/// needs to report it.
///
/// `run: background` commands are fire-and-forget: they used to send stdout to
/// `/dev/null` and keep stderr only when the exit code was non-zero. A command
/// whose whole job is to open a session (`~/bin/workit`, `~/bin/review-linear`
/// through `agent-run` → `banyanctl`) therefore looked like a no-op whenever the
/// launch behind it failed, with no output and no error anywhere the user could
/// see it. A run record keeps the exit status plus a bounded tail of the
/// combined output, and points at the log file the command actually wrote, so
/// "it did nothing" always has an explanation.
struct PaletteCommandRun: Identifiable, Equatable {
    enum Status: Equatable {
        /// A background command is still executing.
        case running
        /// A background command exited 0.
        case succeeded
        /// A background command exited non-zero.
        case failed(exitCode: Int32)
        /// The command could not be started at all (bad cwd, missing log file).
        case couldNotStart
        /// A `run: session` command was handed to a new session. The command's
        /// own outcome is only visible in that session's pane.
        case launchedSession(id: String)
    }

    let id: UUID
    let commandID: String
    /// The expanded title (target placeholders resolved), e.g. `Review ENG-123`.
    let title: String
    /// The expanded shell command, kept so the banner can show what ran.
    let command: String
    let startedAt: Date
    var status: Status
    var finishedAt: Date?
    /// Bounded tail of the command's combined stdout+stderr.
    var outputTail: String
    /// Whether `outputTail` dropped earlier output; the log file has all of it.
    var isOutputTruncated: Bool
    /// Where the command's output was written, when there is a log file.
    var logURL: URL?

    init(
        id: UUID = UUID(),
        commandID: String,
        title: String,
        command: String,
        startedAt: Date,
        status: Status,
        finishedAt: Date? = nil,
        outputTail: String = "",
        isOutputTruncated: Bool = false,
        logURL: URL? = nil
    ) {
        self.id = id
        self.commandID = commandID
        self.title = title
        self.command = command
        self.startedAt = startedAt
        self.status = status
        self.finishedAt = finishedAt
        self.outputTail = outputTail
        self.isOutputTruncated = isOutputTruncated
        self.logURL = logURL
    }

    var isRunning: Bool {
        status == .running
    }

    /// Failures stay visible until dismissed: they are the case that used to be
    /// silent.
    var isFailure: Bool {
        switch status {
        case .failed, .couldNotStart: return true
        case .running, .succeeded, .launchedSession: return false
        }
    }

    var hasOutput: Bool {
        !outputTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The one-line status the banner leads with.
    var headline: String {
        switch status {
        case .running:
            return "Running \(title)…"
        case .succeeded:
            return "\(title) finished"
        case .failed(let exitCode):
            return "\(title) failed (exit \(exitCode))"
        case .couldNotStart:
            return "\(title) could not start"
        case .launchedSession(let id):
            return "\(title) → session \(id)"
        }
    }

    /// The command's own last words, when it had any. Background commands write
    /// their diagnostics to the log, not to a terminal, so this is the only
    /// place the reason for a failure is spelled out.
    var failureDetail: String? {
        guard isFailure, hasOutput else { return nil }
        let lines = outputTail
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let last = lines.last else { return nil }
        return last
    }
}

/// The outcome of a background palette command, as reported by the detached
/// runner.
enum PaletteCommandOutcome: Equatable {
    case finished(exitCode: Int32, output: PaletteCommandOutput)
    case couldNotStart(String)
}

/// A bounded slice of a command's output.
struct PaletteCommandOutput: Equatable {
    let text: String
    let isTruncated: Bool

    static let empty = PaletteCommandOutput(text: "", isTruncated: false)
}

/// Where palette-command output lives, and how much of it the UI keeps in memory.
///
/// The log is the durable half of the fix: the banner can be dismissed and the
/// app can restart, but the run's output is still on disk. Files sit next to the
/// other Banyan state (`Application Support/Banyan/palette-runs/`) rather than in
/// `/tmp`, which the OS may reap.
enum PaletteCommandRunLog {
    /// Enough to explain a failure without dragging a build log into the sidebar.
    static let maxTailBytes = 8 * 1024
    static let maxTailLines = 60

    static func directoryURL(host: HostRuntimeContext) -> URL {
        BanyanDataDirectory.url(
            for: "Banyan/palette-runs",
            environment: host.environment,
            homeDirectory: host.homeDirectory
        )
    }

    /// `<yyyy-MM-dd-HHmmss>-<command id>.log`, with a numeric suffix if two runs
    /// of the same command land in the same second.
    static func fileURL(
        host: HostRuntimeContext,
        commandID: String,
        startedAt: Date,
        fileManager: FileManager = .default
    ) -> URL {
        fileURL(
            in: directoryURL(host: host),
            commandID: commandID,
            startedAt: startedAt,
            fileManager: fileManager
        )
    }

    /// Directory-explicit variant, so the naming rules stay testable without
    /// writing into the real `Application Support` directory.
    static func fileURL(
        in directory: URL,
        commandID: String,
        startedAt: Date,
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileName(commandID: commandID, startedAt: startedAt)
        var candidate = directory.appendingPathComponent("\(base).log")
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix).log")
            suffix += 1
        }
        return candidate
    }

    /// Filename stem: a filename-safe local timestamp plus the command's id, so
    /// a directory listing reads as a run history.
    static func fileName(commandID: String, startedAt: Date) -> String {
        "\(timestamp(for: startedAt))-\(SessionIdentityPolicy.sanitizedID(commandID))"
    }

    /// Reads the tail of a finished command's log. A missing or unreadable file
    /// yields empty output: the run's exit status is still worth reporting.
    static func tail(
        of url: URL,
        maxBytes: Int = maxTailBytes,
        maxLines: Int = maxTailLines
    ) -> PaletteCommandOutput {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .empty }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return .empty }
        let readSize = min(size, UInt64(max(maxBytes, 1)))
        try? handle.seek(toOffset: size - readSize)
        guard let data = try? handle.readToEnd() else { return .empty }
        return truncating(String(decoding: data, as: UTF8.self), maxBytes: maxBytes, maxLines: maxLines)
    }

    /// Keeps the last `maxLines` lines, then the last `maxBytes` of those,
    /// dropping a partial leading line so the tail never starts mid-word.
    static func truncating(
        _ text: String,
        maxBytes: Int = maxTailBytes,
        maxLines: Int = maxTailLines
    ) -> PaletteCommandOutput {
        guard !text.isEmpty else { return .empty }
        var truncated = false
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
            truncated = true
        }
        var result = lines.joined(separator: "\n")
        if result.utf8.count > maxBytes {
            let bytes = Array(result.utf8.suffix(maxBytes))
            var slice = String(decoding: bytes, as: UTF8.self)
            // The byte cap can land inside a multi-byte character; drop what is
            // left of it rather than starting the tail with a replacement glyph.
            slice = String(slice.drop(while: { $0 == "\u{FFFD}" }))
            if let newline = slice.firstIndex(of: "\n") {
                slice = String(slice[slice.index(after: newline)...])
            }
            result = slice
            truncated = true
        }
        return PaletteCommandOutput(
            text: result.trimmingCharacters(in: .whitespacesAndNewlines),
            isTruncated: truncated
        )
    }

    /// Filename-safe local timestamp. `en_US_POSIX` keeps the name stable no
    /// matter the user's locale, and colons stay out of the filename.
    private static func timestamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: date)
    }
}
