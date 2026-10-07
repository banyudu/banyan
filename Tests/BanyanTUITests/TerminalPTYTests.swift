import Foundation
import Testing
@testable import BanyanTUI

@Test func ptyLaunchErrorsAreReportedWithoutLeavingAChild() {
    let queue = DispatchQueue(label: "pty.test.failure")
    #expect(throws: (any Error).self) {
        try queue.sync {
            _ = try TerminalPTY(executable: URL(fileURLWithPath: "/missing-terminal-fixture"),
                                arguments: [], environment: [:], columns: 80, rows: 24,
                                queue: queue, receive: { _ in }, ended: { _ in })
        }
    }
}

@Test func ptyForwardsInputResizesAndReapsOnExit() throws {
    let queue = DispatchQueue(label: "pty.test.roundtrip")
    let ready = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
    var output: [UInt8] = [], exitStatus: Int32?
    let child = try queue.sync {
        try TerminalPTY(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "stty -echo; printf READY; IFS= read -r line; printf 'INPUT:%s\\n' \"$line\"; stty size"],
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
            columns: 40, rows: 10, queue: queue, receive: { bytes in
                output += bytes
                if String(decoding: output, as: UTF8.self).contains("READY") { ready.signal() }
            }, ended: { status in exitStatus = status; ended.signal() })
    }
    defer { queue.sync { child.stop() } }
    #expect(ready.wait(timeout: .now() + 5) == .success)
    try queue.sync {
        try child.resize(columns: 77, rows: 19)
        child.send(Array("hello 世界\r".utf8))
    }
    #expect(ended.wait(timeout: .now() + 5) == .success)
    queue.sync {
        #expect(exitStatus == 0)
        let text = String(decoding: output, as: UTF8.self)
        #expect(text.contains("INPUT:hello 世界"))
        #expect(text.contains("19 77"))
    }
}

@Test func ptyDetachTerminatesOnlyItsClientAndReportsExit() throws {
    let queue = DispatchQueue(label: "pty.test.detach")
    let ready = DispatchSemaphore(value: 0), ended = DispatchSemaphore(value: 0)
    let child = try queue.sync {
        try TerminalPTY(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf READY; read line"],
            environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm-256color"],
            columns: 40, rows: 10, queue: queue,
            receive: { _ in ready.signal() }, ended: { _ in ended.signal() })
    }
    #expect(ready.wait(timeout: .now() + 5) == .success)
    queue.sync { child.stop() }
    #expect(ended.wait(timeout: .now() + 5) == .success)
    queue.sync { child.stop() } // repeated detach must not signal an already reaped PID
}
