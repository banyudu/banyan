#if os(macOS)
import Foundation

/// Watches only process IDs already found by a batched supervisor inspection.
/// No attached tmux client or polling is needed, including after PTY eviction.
@MainActor
public final class SupervisorProcessExitMonitor {
    private struct Watch {
        let source: DispatchSourceProcess
        let generation: UUID
    }
    private var processesBySession: [String: Set<Int32>] = [:]
    private var watches: [Int32: Watch] = [:]
    private let onExit: @MainActor (String) -> Void

    public init(onExit: @escaping @MainActor (String) -> Void) {
        self.onExit = onExit
    }

    deinit {
        for watch in watches.values { watch.source.cancel() }
    }

    public func update(sessionID: String, processIDs: Set<Int32>) {
        processesBySession[sessionID] = processIDs.filter { $0 > 0 }
        reconcile()
    }

    public func retainSessions(_ sessionIDs: Set<String>) {
        processesBySession = processesBySession.filter { sessionIDs.contains($0.key) }
        reconcile()
    }

    private func reconcile() {
        let wanted = processesBySession.values.reduce(into: Set<Int32>()) { $0.formUnion($1) }
        for pid in Set(watches.keys).subtracting(wanted) {
            watches.removeValue(forKey: pid)?.source.cancel()
        }
        for pid in wanted where watches[pid] == nil {
            let generation = UUID()
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.processExited(pid, generation: generation)
                }
            }
            watches[pid] = Watch(source: source, generation: generation)
            source.resume()
        }
    }

    private func processExited(_ pid: Int32, generation: UUID) {
        guard watches[pid]?.generation == generation else { return }
        watches.removeValue(forKey: pid)?.source.cancel()
        let affected = processesBySession.filter { $0.value.contains(pid) }.map(\.key)
        for id in affected {
            processesBySession[id]?.remove(pid)
            onExit(id)
        }
    }
}
#endif
