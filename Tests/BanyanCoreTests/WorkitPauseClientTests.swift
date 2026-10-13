import Foundation
import Testing
@testable import BanyanCore

@Suite struct WorkitPauseClientTests {
    private let request = WorkitPauseRequest(jobID: "job-a", expectedRevision: 3,
        sessionID: "session-a", detail: "Operator paused; acceptance stays unfinished.")

    @Test func configuredArgvAndStateArePassedLiterally() async throws {
        let fixture = try PauseCommandFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let script = fixture.root.appendingPathComponent("fake workit.py")
        let output = fixture.root.appendingPathComponent("invocation.json")
        try Data("""
        import json, os, sys
        with open(sys.argv[1], 'w') as f:
            json.dump({'argv': sys.argv[2:], 'state': os.environ['WORKIT_STATE_DIR'], 'cwd': os.getcwd()}, f)
        print(json.dumps({'id': sys.argv[4], 'sessionID': sys.argv[10], 'revision': 4, 'stage': 'paused'}))
        """.utf8).write(to: script)
        try fixture.configure(invocation: ["/usr/bin/python3", script.path, output.path])
        // Shell syntax and option-looking data stay single argv values.
        let literal = WorkitPauseRequest(jobID: "job-a; $(exit 1)", expectedRevision: 3,
            sessionID: "session-a", detail: "--detail 'quotes' `exit 2`\nsecond line")
        let job = try await WorkitCommandPauseClient(host: fixture.host).pause(literal)
        #expect(job.id == literal.jobID)
        let captured = try JSONDecoder().decode(CapturedInvocation.self, from: Data(contentsOf: output))
        #expect(captured.argv == literal.arguments)
        #expect(captured.state == fixture.state.path)
        #expect(URL(fileURLWithPath: captured.cwd).resolvingSymlinksInPath() == fixture.root.resolvingSymlinksInPath())
    }

    @Test(arguments: ["missing-config", "corrupt-config", "missing-cli", "relative-cli", "relative-state", "older-cli", "nonzero", "invalid-json", "wrong-job", "wrong-session", "stale", "verified"])
    func commandFailuresAreActionable(kind: String) async throws {
        let fixture = try PauseCommandFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let script = fixture.root.appendingPathComponent("fake.py")
        var source = "print('{\"id\":\"job-a\",\"sessionID\":\"session-a\",\"revision\":4,\"stage\":\"paused\"}')"
        switch kind {
        case "older-cli": source = "import sys\nprint('Unknown option --expected-revision', file=sys.stderr)\nsys.exit(1)"
        case "nonzero": source = "import sys\nsys.exit(17)"
        case "invalid-json": source = "print('unreadable')"
        case "wrong-job": source = source.replacingOccurrences(of: "job-a", with: "job-b")
        case "wrong-session": source = source.replacingOccurrences(of: "session-a", with: "session-b")
        case "stale": source = source.replacingOccurrences(of: "revision\":4", with: "revision\":3")
        case "verified": source = source.replacingOccurrences(of: "paused", with: "verified")
        default: break
        }
        try Data(source.utf8).write(to: script)
        if kind != "missing-config" {
            try fixture.configure(invocation: kind == "missing-cli" ? [fixture.root.appendingPathComponent("missing").path]
                : kind == "relative-cli" ? ["workit"] : ["/usr/bin/python3", script.path],
                stateDirectory: kind == "relative-state" ? "state" : nil)
        }
        if kind == "corrupt-config" { try Data("{".utf8).write(to: fixture.config) }
        do {
            _ = try await WorkitCommandPauseClient(host: fixture.host).pause(request)
            Issue.record("Expected failure for \(kind)")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("Workit"))
            #expect(message.contains("retry") || message.contains("retrying"))
            if kind == "older-cli" { #expect(message.contains("upgrade Workit")) }
            if kind == "nonzero" { #expect(message.contains("exit 17")) }
        }
    }
}

private struct CapturedInvocation: Decodable {
    let argv: [String]
    let state: String
    let cwd: String
}

private struct PauseCommandFixture {
    let root: URL
    var state: URL { root.appendingPathComponent("isolated state") }
    var config: URL { root.appendingPathComponent(".banyan/workit.json") }
    var host: HostRuntimeContext {
        HostRuntimeContext(environment: ["PATH": "/usr/bin:/bin", "HOME": root.path,
            "WORKIT_STATE_DIR": root.appendingPathComponent("wrong-state").path],
            homeDirectory: root, currentDirectory: root.path)
    }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("banyan-pause-command-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".banyan"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }
    func configure(invocation: [String], stateDirectory: String? = nil) throws {
        try JSONEncoder().encode(WorkitCommandPauseClient.Configuration(invocation: invocation,
            stateDirectory: stateDirectory ?? state.path)).write(to: config)
    }
}
