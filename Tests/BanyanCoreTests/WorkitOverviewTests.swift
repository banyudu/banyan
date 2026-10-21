import Foundation
import Testing
@testable import BanyanCore

@Suite struct WorkitOverviewTests {
    private let empty = #"{"version":1,"generatedAt":"2026-01-01T00:00:00.000Z","total":0,"truncated":false,"jobs":[]}"#

    @Test func versionBoundsAndLinksAreChecked() throws {
        #expect(try WorkitOverview.decode(Data(empty.utf8)).jobs.isEmpty)
        #expect(throws: (any Error).self) { try WorkitOverview.decode(Data(empty.replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8)) }
        #expect(throws: (any Error).self) { try WorkitOverview.decode(Data(repeating: 32, count: 4 * 1024 * 1024 + 1)) }
        #expect(WorkitJobSummary.webURL("file:///tmp/fixture") == nil)
        #expect(WorkitJobSummary.webURL("https://user:password@example.invalid") == nil)
        #expect(WorkitJobSummary.webURL("https://github.com/example/project/issues/1") != nil)
        #expect(WorkitJobSummary.date("2026-01-01T00:00:00.000Z") != nil)
    }

    @Test func trustedCommandUsesPrivateStateAndOnlyReadsOverview() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("banyan-work-command-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".banyan"), withIntermediateDirectories: true)
        let script = root.appendingPathComponent("fake workit.py")
        let captured = root.appendingPathComponent("invocation.json")
        try Data("""
        import json, os, sys
        with open(sys.argv[1], 'w') as f:
            json.dump({'argv': sys.argv[2:], 'state': os.environ['WORKIT_STATE_DIR']}, f)
        print(\(String(reflecting: empty)))
        """.utf8).write(to: script)
        let config = WorkitCommandPauseClient.Configuration(invocation: ["/usr/bin/python3", script.path, captured.path], stateDirectory: root.appendingPathComponent("private state").path)
        try JSONEncoder().encode(config).write(to: root.appendingPathComponent(".banyan/workit.json"))
        let host = HostRuntimeContext(environment: ["PATH": "/usr/bin:/bin"], homeDirectory: root, currentDirectory: root.path)
        #expect(try await WorkitCommandOverviewClient(host: host).fetch().total == 0)
        let value = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: captured)) as? [String: Any])
        #expect(value["argv"] as? [String] == ["job", "overview", "--format", "json"])
        #expect(value["state"] as? String == config.stateDirectory)
    }
}
