import Foundation

/// Path helpers for the supervisor's hot loops.
///
/// `URL(fileURLWithPath:).lastPathComponent` looks like the obvious way to name
/// an executable, but Foundation resolves every relative path against the
/// working directory, so each construction calls `getcwd(3)` and stats the
/// filesystem. The supervisor asks for the executable name of every token on
/// every process's command line, which turned that convenience into tens of
/// thousands of filesystem syscalls per tick. These helpers answer the same
/// questions from the string alone.
enum ExecutablePath {
    /// The trailing path component of `path`, without touching the filesystem.
    ///
    /// Matches `URL.lastPathComponent` for the shapes the supervisor sees —
    /// absolute paths, bare names, and trailing slashes — except for an empty
    /// input, which yields an empty name here rather than the last component of
    /// the process's working directory.
    static func lastComponent<S: StringProtocol>(_ path: S) -> S.SubSequence {
        var end = path.endIndex
        while end > path.startIndex, path[path.index(before: end)] == "/" {
            end = path.index(before: end)
        }
        var start = end
        while start > path.startIndex {
            let previous = path.index(before: start)
            if path[previous] == "/" { break }
            start = previous
        }
        return path[start..<end]
    }

    /// The executable name of `path`, lowercased for case-insensitive matching.
    static func lowercasedName<S: StringProtocol>(_ path: S) -> String {
        String(lastComponent(path)).lowercased()
    }
}
