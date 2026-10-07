import CTerminalPTY
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

protocol TerminalTransport: AnyObject {
    func send(_ bytes: [UInt8])
    func resize(columns: Int, rows: Int) throws
    func stop()
}

/// All descriptor/PID operations and callbacks run on the supplied serial queue.
/// waitid leaves an exited child unreaped until that queue relinquishes ownership,
/// so detach cannot accidentally signal a PID reused by an unrelated process.
final class TerminalPTY: TerminalTransport {
    private let queue: DispatchQueue
    private var descriptor: Int32 = -1
    private var pid: pid_t = 0
    private var reader: DispatchSourceRead?
    private var writer: DispatchSourceWrite?
    private var pending: [UInt8] = []
    private var offset = 0
    private let receive: ([UInt8]) -> Void
    private let ended: (Int32) -> Void

    init(executable: URL, arguments: [String], environment: [String: String],
         columns: Int, rows: Int, queue: DispatchQueue,
         receive: @escaping ([UInt8]) -> Void, ended: @escaping (Int32) -> Void) throws {
        self.queue = queue
        self.receive = receive
        self.ended = ended
        let argv = ([executable.path] + arguments).map { strdup($0) }
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
        defer { (argv + envp).forEach { free($0) } }
        let error = (argv + [nil]).withUnsafeBufferPointer { args in
            (envp + [nil]).withUnsafeBufferPointer { env in
                banyan_pty_spawn(executable.path, args.baseAddress, env.baseAddress,
                                 UInt16(clamping: columns), UInt16(clamping: rows), &descriptor, &pid)
            }
        }
        guard error == 0 else { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        let reader = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        let master = descriptor
        self.reader = reader
        reader.setEventHandler { [weak self] in self?.drain() }
        reader.setCancelHandler { close(master) }
        reader.resume()
        let child = pid
        // One blocking wait per child, no repeating timer or process-table polling.
        DispatchQueue.global(qos: .utility).async { [self] in
            let status = banyan_pty_wait(child)
            queue.async { [self] in
                drain()
                closeDescriptor()
                pid = 0
                banyan_pty_reap(child)
                ended(status)
            }
        }
    }

    func send(_ bytes: [UInt8]) {
        guard descriptor >= 0, pid != 0, !bytes.isEmpty else { return }
        if offset > 0 { pending.removeFirst(offset); offset = 0 }
        pending.append(contentsOf: bytes)
        flush()
    }

    private func flush() {
        while descriptor >= 0 && offset < pending.count {
            let count = pending.withUnsafeBytes { bytes in
                write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 { offset += count; continue }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                if writer == nil {
                    let source = DispatchSource.makeWriteSource(fileDescriptor: descriptor, queue: queue)
                    writer = source
                    source.setEventHandler { [weak self] in self?.flush() }
                    source.resume()
                }
                return
            }
            stop()
            return
        }
        pending.removeAll(keepingCapacity: true); offset = 0
        writer?.cancel(); writer = nil
    }

    private func drain() {
        guard descriptor >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 65536)
        // Bound each readiness callback so continuous output cannot starve input,
        // resize, frame deadlines or termination on the same serial queue.
        for _ in 0..<8 {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 { receive(Array(buffer.prefix(count))); continue }
            if count < 0 && errno == EINTR { continue }
            if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                closeDescriptor()
            }
            return
        }
    }

    func resize(columns: Int, rows: Int) throws {
        guard descriptor >= 0 else { return }
        let error = banyan_pty_resize(descriptor, UInt16(clamping: columns), UInt16(clamping: rows))
        if error != 0 { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
    }

    func stop() {
        closeDescriptor()
        guard pid != 0 else { return }
        let child = pid
        kill(child, SIGTERM)
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.pid == child else { return }
            kill(child, SIGKILL)
        }
    }

    private func closeDescriptor() {
        reader?.cancel(); reader = nil
        writer?.cancel(); writer = nil
        // Dispatch must finish unregistering its source before the fd can be
        // reused by the next attachment during a rapid session switch.
        descriptor = -1
        pending.removeAll(); offset = 0
    }
}
