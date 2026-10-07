import Foundation

/// The tmux server owns session state; this object owns just the selected client.
/// A generation token discards late reads/exits after switch, detach or reconnect.
final class EmbeddedTerminal {
    typealias Factory = (Int, Int, @escaping ([UInt8]) -> Void, @escaping (Int32) -> Void) throws -> any TerminalTransport
    private let queue = DispatchQueue(label: "banyan.tui.terminal")
    private let changed: () -> Void
    private var transport: (any TerminalTransport)?
    private var grid: TerminalGridModel?
    private var generation = 0
    private var scheduled = false
    private(set) var sessionName: String?
    private var message: String?
    private var reconnect: Factory?
    private var size = (columns: 1, rows: 1)
    private var retryCount = 0
    private var stopped = true

    init(changed: @escaping () -> Void) { self.changed = changed }

    func connect(sessionName: String, columns: Int, rows: Int, factory: @escaping Factory) {
        queue.sync {
            stopOnQueue()
            self.sessionName = sessionName
            size = (max(1, columns), max(1, rows))
            reconnect = factory
            retryCount = 0
            stopped = false
            launch()
        }
    }

    private func launch() {
        guard let reconnect, !stopped else { return }
        generation += 1
        let token = generation
        grid = TerminalGridModel(columns: size.columns, rows: size.rows)
        grid?.reply = { [weak self] bytes in self?.transport?.send(bytes) }
        do {
            transport = try reconnect(size.columns, size.rows, { [weak self] bytes in
                guard let self, self.generation == token, !self.stopped else { return }
                self.grid?.feed(bytes)
                self.scheduleFrame()
            }, { [weak self] status in
                guard let self, self.generation == token, !self.stopped else { return }
                self.transport = nil
                self.message = "Terminal disconnected (\(status)); Enter retries, f attaches full screen"
                self.changed()
                // Bounded, one-shot recovery. A missing server/session settles idle.
                if self.retryCount < 3 {
                    self.retryCount += 1
                    self.queue.asyncAfter(deadline: .now() + Double(self.retryCount)) { [weak self] in
                        guard let self, self.generation == token, !self.stopped else { return }
                        self.launch()
                    }
                }
            })
            message = nil
        } catch {
            message = "Terminal: \(error.localizedDescription); Enter retries, f attaches full screen"
        }
        changed()
    }

    /// Factory callbacks must be on this queue (TerminalPTY is constructed here).
    func connect(executable: URL, arguments: [String], environment: [String: String],
                 sessionName: String, columns: Int, rows: Int) {
        var environment = environment
        environment.removeValue(forKey: "TMUX")
        environment.removeValue(forKey: "TMUX_PANE")
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        connect(sessionName: sessionName, columns: columns, rows: rows) { [queue] columns, rows, receive, ended in
            try TerminalPTY(executable: executable, arguments: arguments, environment: environment,
                            columns: columns, rows: rows, queue: queue, receive: receive, ended: ended)
        }
    }

    func send(_ bytes: [UInt8]) { queue.sync { transport?.send(bytes) } }

    func resize(columns: Int, rows: Int) {
        queue.sync {
            let next = (columns: max(1, columns), rows: max(1, rows))
            guard next != size else { return }
            size = next
            grid?.resize(columns: next.columns, rows: next.rows)
            do { try transport?.resize(columns: next.columns, rows: next.rows) }
            catch { message = "Resize: \(error.localizedDescription)" }
            scheduleFrame()
        }
    }

    func snapshot() -> (grid: TerminalGrid?, message: String?) {
        queue.sync { (grid?.snapshot(), message) }
    }

    func stop() { queue.sync { stopOnQueue() } }

    private func stopOnQueue() {
        stopped = true
        generation += 1
        transport?.stop(); transport = nil
        reconnect = nil; sessionName = nil; grid = nil; message = nil
    }

    private func scheduleFrame() {
        guard !scheduled else { return }
        scheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(33)) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.changed()
        }
    }
}
