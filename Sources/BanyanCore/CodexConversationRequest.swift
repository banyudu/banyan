import Foundation

public enum CodexApprovalDecision: String, CaseIterable, Sendable {
    case accept, acceptForSession, decline, cancel

    public var label: String {
        switch self {
        case .accept: return "Approve Once"
        case .acceptForSession: return "Approve for Session"
        case .decline: return "Decline"
        case .cancel: return "Cancel Turn"
        }
    }
}

public struct CodexInputQuestion: Identifiable, Sendable {
    public let id: String
    public let header: String
    public let question: String
    public let options: [CodexJSONValue]
    public let allowsOther: Bool
    public let isSecret: Bool
}

/// Only recognized requests get an approval action. Raw fields remain visible
/// for managed network prompts, extra permissions, and future protocol fields.
public struct CodexConversationRequest: Sendable {
    public let request: CodexServerRequest
    public init(_ request: CodexServerRequest) { self.request = request }

    public var isApproval: Bool {
        ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"].contains(request.method)
    }
    public var isInput: Bool { request.method == "item/tool/requestUserInput" }
    public var title: String {
        if isInput { return "Input requested" }
        if request.params.objectValue?["networkApprovalContext"]?.objectValue != nil { return "Network access requested" }
        if request.method == "item/commandExecution/requestApproval" { return "Command approval requested" }
        if request.method == "item/fileChange/requestApproval" { return "File change approval requested" }
        return "Unsupported request: \(request.method)"
    }
    public var decisions: [CodexApprovalDecision] {
        guard isApproval else { return [] }
        if let available = request.params.objectValue?["availableDecisions"], available != .null {
            return CodexApprovalDecision.allCases.filter { available.arrayValue.contains(.string($0.rawValue)) }
        }
        // Do not silently introduce a persistent grant when none was offered.
        return [.accept, .decline, .cancel]
    }
    public var questions: [CodexInputQuestion] {
        guard isInput else { return [] }
        return (request.params.objectValue?["questions"]?.arrayValue ?? []).compactMap { raw in
            let value = raw.objectValue ?? [:]
            guard let id = value["id"]?.stringValue, let question = value["question"]?.stringValue else { return nil }
            return .init(id: id, header: value["header"]?.stringValue ?? "Answer",
                question: question, options: value["options"]?.arrayValue ?? [],
                allowsOther: value["isOther"] == .bool(true), isSecret: value["isSecret"] == .bool(true))
        }
    }

    public func approvalReply(_ decision: CodexApprovalDecision) throws -> CodexServerReply {
        guard decisions.contains(decision) else {
            throw CodexAppServerError.protocolViolation("This decision was not offered by the Codex request")
        }
        return .result(.object(["decision": .string(decision.rawValue)]))
    }

    public func inputReply(_ answers: [String: String]) throws -> CodexServerReply {
        guard isInput, !questions.isEmpty,
              questions.count == (request.params.objectValue?["questions"]?.arrayValue.count ?? 0),
              Set(questions.map(\.id)).count == questions.count else {
            throw CodexAppServerError.protocolViolation("This input request cannot be answered by this client")
        }
        var result: [String: CodexJSONValue] = [:]
        for question in questions {
            guard let answer = answers[question.id], !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CodexAppServerError.protocolViolation("Answer every question before sending")
            }
            let labels = question.options.compactMap { $0.objectValue?["label"]?.stringValue }
            guard labels.isEmpty || question.allowsOther || labels.contains(answer) else {
                throw CodexAppServerError.protocolViolation("Choose one of the offered answers")
            }
            result[question.id] = .object(["answers": .array([.string(answer)])])
        }
        return .result(.object(["answers": .object(result)]))
    }

    /// The input schema has no fabricated decline answer. Empty answers mean
    /// skipped input; callers also interrupt the turn when the user cancels.
    public var skippedInputReply: CodexServerReply { .result(.object(["answers": .object([:])])) }
}
