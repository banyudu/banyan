import Foundation

protocol TmuxControlModeClient: AnyObject {
    func start(sessionName: String, columns: Int, rows: Int, output: @escaping (Data) -> Void) throws
    func send(_ data: Data)
    func resize(columns: Int, rows: Int)
    func stop()
}

/// tmux control mode keeps the Banyan TUI in control of the screen. `%output`
/// notifications are decoded here; the backing session remains attached to
/// tmux when the client is stopped or the selected session changes.
final class ProcessTmuxControlModeClient: TmuxControlModeClient {
    private let executableURL: URL
    private var process: Process?
    private var input: FileHandle?
    private var target = ""
    private var controlBuffer = ""
    private var outputTask: Task<Void, Never>?

    init(executableURL: URL) { self.executableURL = executableURL }

    func start(sessionName: String, columns: Int, rows: Int, output: @escaping (Data) -> Void) throws {
        stop()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-L", "banyan", "-C", "attach-session", "-t", sessionName]
        let stdin = Pipe(); let stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.standardError
        try process.run()
        self.process = process; input = stdin.fileHandleForWriting
        target = sessionName
        let handle = stdout.fileHandleForReading
        outputTask = Task.detached { [weak self] in
            while let self, !Task.isCancelled {
                let data = handle.availableData
                if data.isEmpty { break }
                self.consume(data, output: output)
            }
        }
        resize(columns: columns, rows: rows)
    }

    func send(_ data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        guard !hex.isEmpty else { return }
        write("send-keys -t \(target) -H \(hex)\n")
    }

    func resize(columns: Int, rows: Int) { write("refresh-client -C \(columns)x\(rows)\n") }

    func stop() { outputTask?.cancel(); outputTask = nil; try? input?.close(); input = nil; process?.terminate(); process = nil }

    private func write(_ command: String) { try? input?.write(contentsOf: Data(command.utf8)) }

    private func consume(_ data: Data, output: @escaping (Data) -> Void) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        controlBuffer += text
        while let newline = controlBuffer.firstIndex(of: "\n") {
            let line = String(controlBuffer[..<newline])
            controlBuffer = String(controlBuffer[controlBuffer.index(after: newline)...])
            guard line.hasPrefix("%output ") else { continue }
            let parts = line.split(separator: " ", maxSplits: 2)
            guard parts.count == 3 else { continue }
            output(Self.decode(String(parts[2])))
        }
    }

    static func decode(_ value: String) -> Data {
        var result = Data(); var index = value.startIndex
        while index < value.endIndex {
            let character = value[index]; index = value.index(after: index)
            guard character == "\\", index < value.endIndex else { result.append(contentsOf: String(character).utf8); continue }
            let next = value[index]; index = value.index(after: index)
            if next == "n" { result.append(10) }
            else if next == "r" { result.append(13) }
            else if next == "t" { result.append(9) }
            else if next.isNumber { var octal = String(next); for _ in 0..<2 where index < value.endIndex && value[index].isNumber { octal.append(value[index]); index = value.index(after: index) }; result.append(UInt8(octal, radix: 8) ?? 0) }
            else { result.append(contentsOf: String(next).utf8) }
        }
        return result
    }
}
