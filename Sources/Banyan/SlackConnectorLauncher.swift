import Foundation

struct SlackConnectorLaunch {
    let executable: URL
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL
}

@MainActor
protocol SlackConnectorRunning: AnyObject { func terminate() }

@MainActor
protocol SlackConnectorLaunching {
    func launch(_ specification: SlackConnectorLaunch, status: @escaping @MainActor (String) -> Void,
                exited: @escaping @MainActor (Int32) -> Void) throws -> any SlackConnectorRunning
}

@MainActor
struct LocalSlackConnectorLauncher: SlackConnectorLaunching {
    func launch(_ specification: SlackConnectorLaunch, status: @escaping @MainActor (String) -> Void,
                exited: @escaping @MainActor (Int32) -> Void) throws -> any SlackConnectorRunning {
        let child = SlackConnectorChild(specification: specification, status: status, exited: exited)
        try child.start()
        return child
    }
}

@MainActor
private final class SlackConnectorChild: SlackConnectorRunning {
    private let process = Process()
    private let output = Pipe()
    private let status: @MainActor (String) -> Void
    private let exited: @MainActor (Int32) -> Void
    private var buffered = Data()

    init(specification: SlackConnectorLaunch, status: @escaping @MainActor (String) -> Void,
         exited: @escaping @MainActor (Int32) -> Void) {
        self.status = status; self.exited = exited
        process.executableURL = specification.executable
        process.arguments = specification.arguments
        process.environment = specification.environment
        process.currentDirectoryURL = specification.workingDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        // Never log SDK diagnostics: an exception can contain credentials or content.
        process.standardError = FileHandle.nullDevice
    }

    func start() throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consume(data) }
        }
        process.terminationHandler = { [weak self] child in
            let code = child.terminationStatus
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.output.fileHandleForReading.readabilityHandler = nil
                self.exited(code)
            }
        }
        do { try process.run() }
        catch { output.fileHandleForReading.readabilityHandler = nil; throw error }
    }

    func terminate() { if process.isRunning { process.terminate() } }

    private func consume(_ data: Data) {
        buffered.append(data)
        // This channel carries only short, fixed status lines. Discard unknown
        // output rather than retaining or displaying potentially sensitive text.
        if buffered.count > 4096 { buffered.removeAll(); return }
        while let newline = buffered.firstIndex(of: 10) {
            let line = String(decoding: buffered[..<newline], as: UTF8.self)
            buffered.removeSubrange(...newline)
            switch line {
            case "BANYAN_SLACK_STATUS=connecting": status("connecting")
            case "BANYAN_SLACK_STATUS=connected": status("connected")
            case "BANYAN_SLACK_STATUS=offline": status("offline")
            default: break
            }
        }
    }
}
