import Foundation

extension Pipe {
    /// Closes both ends of the pipe, returning its two descriptors to the process.
    ///
    /// Dropping a `Pipe` is not enough to close it. `Process` retains whatever it was
    /// handed for `standardInput`/`standardOutput`/`standardError`, and Foundation keeps a
    /// launched `Process` alive past the caller's scope, so a pipe that is merely left to
    /// ARC never deallocates: its descriptors stay open for the life of the app. At one
    /// descriptor per pipe per run, a long-lived session that shells out on a timer walks
    /// its way to `EMFILE`, and the first casualty is rarely the subprocess code — it is
    /// whichever unrelated subsystem next needs to open a file. CoreAnimation, for one,
    /// lazily `open`s its Metal shader library on first GPU-backed draw and asserts rather
    /// than fails when that returns nil, taking the whole app down.
    ///
    /// Safe to call more than once, and after either end has already been closed:
    /// `FileHandle` clears its descriptor on the first close and throws thereafter.
    public func closeBothEnds() {
        try? fileHandleForReading.close()
        try? fileHandleForWriting.close()
    }
}
