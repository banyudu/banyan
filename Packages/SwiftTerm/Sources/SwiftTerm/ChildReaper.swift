//
//  ChildReaper.swift
//
//  Owns the corpses of the children `LocalProcess` forks, so that reaping a
//  child never depends on anyone still being interested in its exit.
//

#if !os(iOS) && !os(Windows)
import Foundation
import Dispatch

#if os(macOS)

/// Takes ownership of every child pid `LocalProcess` forks and collects it
/// exactly once, whatever happens to the `LocalProcess` in the meantime.
///
/// Reaping used to be a side effect of *listening* for the exit: the only
/// `waitpid` lived in `LocalProcess`'s own `.exit` dispatch source, and every
/// teardown path cancelled that source. `terminate()` in particular sent
/// `SIGTERM` and cancelled the monitor in the same breath, so the child it had
/// just signalled could never be collected — one stranded zombie per detach,
/// and under attach/detach churn the count only ever grew.
///
/// The reaper separates the two concerns. A client adopts a pid and may stop
/// listening, or be deallocated, at any moment; the pid stays adopted until
/// `waitpid` has actually collected it.
final class ChildReaper: @unchecked Sendable {
    static let shared = ChildReaper()

    /// How long a child gets to honour `SIGTERM` before it is `SIGKILL`ed. A
    /// `tmux attach-session` client detaches well inside this; the budget only
    /// matters for a child that ignores the signal, which would otherwise
    /// outlive its owner as a zombie forever.
    static let terminationGrace: TimeInterval = 2

    /// A waiter does nothing but park in `waitpid`, so it needs no room to
    /// work. The default 512 KB per thread would be pure waste at one thread
    /// per live terminal.
    private static let waiterStackSize = 64 * 1024

    private final class Adoption {
        var notify: ((Int32) -> Void)?
        var notifyQueue: DispatchQueue?
        var forceKill: DispatchWorkItem?

        /// Set by the waiter the instant `waitpid` returns, which is earlier
        /// than the queue hop that retires the adoption. Without it a pending
        /// force-kill could fire in that gap and signal a pid the kernel has
        /// already handed to somebody else.
        private let lock = NSLock()
        private var reaped = false

        var isReaped: Bool {
            lock.lock()
            defer { lock.unlock() }
            return reaped
        }

        func markReaped() {
            lock.lock()
            reaped = true
            lock.unlock()
        }
    }

    /// Serializes every mutation of `adopted`, and every signal sent to an
    /// adopted pid.
    private let queue = DispatchQueue(label: "SwiftTerm.ChildReaper")
    private var adopted: [pid_t: Adoption] = [:]

    /// Takes ownership of `pid`. Its raw wait status is delivered to `onExit` on
    /// `notifyQueue`, unless `stopListening(pid:)` runs first.
    func adopt(pid: pid_t, notifyOn notifyQueue: DispatchQueue, onExit: @escaping (Int32) -> Void) {
        guard pid > 0 else { return }
        queue.async {
            guard self.adopted[pid] == nil else { return }
            let adoption = Adoption()
            adoption.notify = onExit
            adoption.notifyQueue = notifyQueue
            self.adopted[pid] = adoption
            self.startWaiter(for: pid, adoption: adoption)
        }
    }

    /// Stops delivering the exit status without giving up the reap. Used when
    /// the owner detaches deliberately, or goes away entirely.
    func stopListening(pid: pid_t) {
        guard pid > 0 else { return }
        queue.async {
            guard let adoption = self.adopted[pid] else { return }
            adoption.notify = nil
            adoption.notifyQueue = nil
        }
    }

    /// Signals the child and guarantees it is collected: `SIGTERM` first, then
    /// `SIGKILL` once the grace elapses.
    ///
    /// Signalling goes through here rather than through a bare `kill` at the
    /// call site so it cannot reach an unrelated process: a pid is only ours
    /// while it is adopted, and once reaped the number is free for the kernel
    /// to hand to somebody else.
    func terminate(pid: pid_t, grace: TimeInterval = ChildReaper.terminationGrace) {
        guard pid > 0 else { return }
        queue.async {
            guard let adoption = self.adopted[pid], adoption.forceKill == nil, !adoption.isReaped else {
                return
            }
            kill(pid, SIGTERM)

            let forceKill = DispatchWorkItem { [weak self] in
                guard let self, self.adopted[pid] === adoption, !adoption.isReaped else { return }
                kill(pid, SIGKILL)
            }
            adoption.forceKill = forceKill
            self.queue.asyncAfter(deadline: .now() + grace, execute: forceKill)
        }
    }

    /// Parks a thread in `waitpid` until the child exits.
    ///
    /// A dispatch process source is the obvious tool, and is what this used to
    /// use, but it cannot be relied on to reap. libdispatch registers the
    /// underlying `EVFILT_PROC` note asynchronously, and registering one
    /// against a pid that has already become a zombie fails, so a child that
    /// exits inside that window is never reported at all. Measured at 1-3% of
    /// immediately-exiting children — which is exactly the shape of `tmux
    /// attach-session` against a session that no longer exists.
    ///
    /// A blocking `waitpid` has no such window: from `fork` until the reap, the
    /// pid is reserved to us and nobody else can answer for it. The waiter is
    /// parked in the kernel, costs no CPU, and exits the moment its child does,
    /// so the number of them tracks live terminals rather than total attaches.
    private func startWaiter(for pid: pid_t, adoption: Adoption) {
        let waiter = Thread {
            var status: Int32 = 0
            while true {
                let result = waitpid(pid, &status, 0)
                if result == pid { break }
                if result < 0 && errno == EINTR { continue }
                // `ECHILD`, or anything else we cannot act on: the pid is no
                // longer ours to wait for, and we have no status to report.
                status = 0
                break
            }
            adoption.markReaped()
            let collected = status
            self.queue.async { self.retire(pid: pid, status: collected) }
        }
        waiter.stackSize = ChildReaper.waiterStackSize
        waiter.name = "SwiftTerm.ChildReaper.\(pid)"
        waiter.start()
    }

    private func retire(pid: pid_t, status: Int32) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let adoption = adopted.removeValue(forKey: pid) else { return }
        adoption.forceKill?.cancel()
        adoption.forceKill = nil
        if let notify = adoption.notify, let notifyQueue = adoption.notifyQueue {
            notifyQueue.async { notify(status) }
        }
    }
}

#endif
#endif
