import BanyanCore
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

enum TUIEvent {
    case input([UInt8])
    case action(SessionListAction)
    case redraw
    case resize
    case flushInput(Int)
    case flushNavigation(Int)
    case quit
}

/// A coalescing self-pipe wakes poll for terminal output and OS signals. The
/// screen can update while stdin is idle, with no periodic wakeups.
final class TUIEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [TUIEvent] = []
    private var descriptors: [Int32] = [-1, -1]
    private var signals: [DispatchSourceSignal] = []
    private var previousSignals: [(Int32, sig_t?)] = []
    var descriptor: Int32 { descriptors[0] }

    init(watchSignals: Bool = false) throws {
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EMFILE) }
        for fd in descriptors {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        if watchSignals {
            for number in [SIGWINCH, SIGINT, SIGTERM, SIGHUP] {
                previousSignals.append((number, signal(number, SIG_IGN)))
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { [weak self] in
                    self?.post(number == SIGWINCH ? .resize : .quit)
                }
                source.resume()
                signals.append(source)
            }
        }
    }

    func post(_ event: TUIEvent) {
        lock.lock(); defer { lock.unlock() }
        // Repaint requests are level triggered; one outstanding request is enough.
        if case .redraw = event, pending.contains(where: { if case .redraw = $0 { return true }; return false }) { return }
        let wake = pending.isEmpty
        pending.append(event)
        if wake {
            var byte: UInt8 = 1
            _ = write(descriptors[1], &byte, 1)
        }
    }

    func take() -> TUIEvent? {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return nil }
        let event = pending.removeFirst()
        if pending.isEmpty {
            var byte: UInt8 = 0
            _ = read(descriptors[0], &byte, 1)
        }
        return event
    }

    deinit {
        signals.forEach { $0.cancel() }
        previousSignals.forEach { _ = signal($0.0, $0.1) }
        descriptors.forEach { close($0) }
    }
}
