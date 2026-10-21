import Foundation

public struct CoordinationControlPayload: Decodable {
    public let apiVersion: String?
    public let action: String
    public let id: String
    public let groupID: String
    public let parent: String?
    public let worker: String?
    public let runID: String?
    public let jobID: String?
    public let revision: LenientInt?
    public let wakeID: String?
    public let text: String?
    public let outcome: String?
    public let detail: String?
    public let interventionID: String?
}

public struct CoordinationIntervention: Codable, Equatable, Sendable {
    public let id: String
    public let at: String
    public let text: String
    public init(text: String) {
        id = UUID().uuidString
        at = ISO8601DateFormatter().string(from: Date())
        self.text = String(text.prefix(4000))
    }
}

/// Bindings and delivery receipts are independent of a session's issue workflow.
/// Runtime data never goes into shared agent instructions.
public struct SessionCoordinationJournal: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public var bindings: SessionWorkflowJournal { .init(directory: directory.appendingPathComponent("bindings")) }

    private func inputURL(_ id: String) throws -> URL {
        guard id.range(of: #"^[A-Za-z0-9_.-]{1,128}$"#, options: .regularExpression) != nil,
              id != ".", id != ".." else { throw WorkflowError.refused("invalid coordination session ID") }
        return directory.appendingPathComponent("inputs").appendingPathComponent(id + ".json")
    }
    public func interventions(id: String) throws -> [CoordinationIntervention] {
        let url = try inputURL(id)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([CoordinationIntervention].self, from: Data(contentsOf: url))
    }
    public func appendIntervention(id: String, text: String) throws {
        let url = try inputURL(id)
        var values = try interventions(id: id)
        values.append(.init(text: text))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(values).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
