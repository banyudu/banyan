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
    public let inspectionID: String?
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

    private var inputs: SessionJournalStorage<[CoordinationIntervention]> {
        .init(directory: directory.appendingPathComponent("inputs"))
    }
    public func interventions(id: String) throws -> [CoordinationIntervention] {
        try inputs.load(id: id) ?? []
    }
    public func appendIntervention(id: String, text: String) throws {
        var values = try interventions(id: id)
        values.append(.init(text: text))
        try inputs.save(values, id: id)
    }
}
