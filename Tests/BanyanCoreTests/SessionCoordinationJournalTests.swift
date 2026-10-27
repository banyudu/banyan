import Foundation
import Testing
@testable import BanyanCore

@Suite struct SessionCoordinationJournalTests {
    @Test func arbitraryIDsRemainDistinctAndCannotEscapeTheJournal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("coordination")
        let journal = SessionCoordinationJournal(directory: directory)
        let ids = ["协调者", "worker: [review]!?", String(repeating: "long-session-", count: 1000),
            "../escape", "../../escape", "/absolute/path", ".", "..", "a/b", "a?b", "a-b",
            "extended", "records", "session\nwith\nlines", "null\0byte"]
        for (index, id) in ids.enumerated() {
            #expect(try journal.bindings.load(id: id) == nil)
            #expect(try journal.interventions(id: id).isEmpty)
            try journal.bindings.save(.init(owner: "workit-coordinator", jobID: "group-\(index)", revision: index,
                state: .working, wake: .init(id: "wake-\(index)", status: .pending)), id: id)
            try journal.appendIntervention(id: id, text: "Input \(index)")
        }
        let restored = SessionCoordinationJournal(directory: directory)
        try restored.appendIntervention(id: ids[0], text: "Second input")
        for (index, id) in ids.enumerated() {
            let binding = try #require(try restored.bindings.load(id: id))
            #expect(binding.jobID == "group-\(index)")
            #expect(binding.wake == .init(id: "wake-\(index)", status: .pending))
            #expect(throws: (any Error).self) {
                try binding.shouldDeliver(jobID: binding.jobID, revision: index, wakeID: "wake-\(index)")
            }
            let inputs = try restored.interventions(id: id)
            #expect(inputs.map(\.text) == (index == 0 ? ["Input 0", "Second input"] : ["Input \(index)"]))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["coordination"])
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["bindings", "inputs"])
        for child in ["bindings", "inputs"] {
            let file = directory.appendingPathComponent(child + "/extended/records.json")
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            #expect(permissions?.intValue == 0o600)
        }
    }

    @Test func legacyBindingsAndInputsAreReadAndUpdatedInPlace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bindingURL = root.appendingPathComponent("bindings/legacy-id.json")
        let inputURL = root.appendingPathComponent("inputs/legacy-id.json")
        let binding = SessionWorkflow(owner: "workit-coordinator", jobID: "group-a", revision: 1, state: .working,
            wake: .init(id: "old-wake", status: .uncertain))
        let input = CoordinationIntervention(text: "Original input")
        for url in [bindingURL, inputURL] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try JSONEncoder().encode(binding).write(to: bindingURL)
        try JSONEncoder().encode([input]).write(to: inputURL)
        let journal = SessionCoordinationJournal(directory: root)
        #expect(try journal.bindings.load(id: "legacy-id") == binding)
        #expect(try journal.interventions(id: "legacy-id") == [input])
        try journal.appendIntervention(id: "legacy-id", text: "New input")
        #expect(try JSONDecoder().decode([CoordinationIntervention].self, from: Data(contentsOf: inputURL)).count == 2)
        let next = SessionWorkflow(owner: binding.owner, jobID: binding.jobID, revision: 2, state: .verified, wake: binding.wake)
        try journal.bindings.save(next, id: "legacy-id")
        #expect(try JSONDecoder().decode(SessionWorkflow.self, from: Data(contentsOf: bindingURL)) == next)
    }

    @Test(arguments: ["bindings", "inputs"])
    func corruptExtendedRecordsAreNeverSilentlyReplaced(kind: String) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = SessionCoordinationJournal(directory: root)
        let id = "协调者"
        let binding = SessionWorkflow(owner: "workit-coordinator", jobID: "group-a", revision: 1, state: .working)
        try journal.bindings.save(binding, id: id)
        try journal.appendIntervention(id: id, text: "Original input")
        let file = root.appendingPathComponent(kind + "/extended/records.json")
        let corrupt = Data("{".utf8)
        try corrupt.write(to: file)
        if kind == "bindings" {
            #expect(throws: (any Error).self) { try journal.bindings.load(id: id) }
            #expect(throws: (any Error).self) { try journal.bindings.save(binding, id: "another:session") }
        } else {
            #expect(throws: (any Error).self) { try journal.interventions(id: id) }
            #expect(throws: (any Error).self) { try journal.appendIntervention(id: "another:session", text: "New input") }
        }
        #expect(try Data(contentsOf: file) == corrupt)
    }
}
