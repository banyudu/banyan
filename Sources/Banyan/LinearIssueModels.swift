import BanyanCore
import Foundation

struct LinearIssueDetails: Equatable, Identifiable {
    let id: String
    let identifier: String
    let title: String
    let description: String?
    let url: String
    let priority: Int?
    let estimate: Double?
    let updatedAt: String?
    let state: LinearWorkflowState
    let workflowStates: [LinearWorkflowState]
    let assigneeName: String?
    let creatorName: String?
    let teamName: String?
    let projectName: String?
    let cycleName: String?
    let labels: [LinearIssueLabel]
    let comments: [LinearIssueComment]
    let attachments: [LinearIssueAttachment]

    func applying(description: String?) -> LinearIssueDetails {
        LinearIssueDetails(
            id: id, identifier: identifier, title: title, description: description,
            url: url, priority: priority, estimate: estimate, updatedAt: updatedAt,
            state: state, workflowStates: workflowStates, assigneeName: assigneeName,
            creatorName: creatorName, teamName: teamName, projectName: projectName,
            cycleName: cycleName, labels: labels, comments: comments, attachments: attachments
        )
    }

    func applying(status snapshot: LinearIssueStatusSnapshot) -> LinearIssueDetails {
        LinearIssueDetails(
            id: id,
            identifier: identifier,
            title: title,
            description: description,
            url: url,
            priority: priority,
            estimate: estimate,
            updatedAt: snapshot.updatedAt ?? updatedAt,
            state: snapshot.state,
            workflowStates: snapshot.workflowStates.isEmpty ? workflowStates : snapshot.workflowStates,
            assigneeName: assigneeName,
            creatorName: creatorName,
            teamName: teamName,
            projectName: projectName,
            cycleName: cycleName,
            labels: labels,
            comments: comments,
            attachments: attachments
        )
    }
}

struct LinearIssueStatusSnapshot: Equatable {
    let identifier: String
    let updatedAt: String?
    let state: LinearWorkflowState
    let workflowStates: [LinearWorkflowState]
}

struct LinearWorkflowState: Equatable, Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let type: String?
    let color: String?
    let position: Double?
}

struct LinearIssueLabel: Equatable, Identifiable, Codable, Sendable {
    var id: String { name }
    let name: String
    let color: String?
}

struct LinearIssueComment: Equatable, Identifiable {
    let id: String
    let body: String
    let createdAt: String?
    let updatedAt: String?
    let userName: String?
}

struct LinearIssueAttachment: Equatable, Identifiable {
    let id: String
    let title: String
    let url: String
}

struct LinearIssueSummary: Equatable, Identifiable, Codable, Sendable {
    let id: String
    let identifier: String
    let title: String
    let url: String
    let priority: Int?
    let priorityLabel: String?
    let updatedAt: String?
    let state: LinearWorkflowState
    let assigneeName: String?
    let teamKey: String?
    let teamName: String?
    let projectName: String?
    let cycleName: String?
    let labels: [LinearIssueLabel]
}

func linearIssueStateCountSummary(_ issues: [LinearIssueSummary]) -> String {
    let counts = Dictionary(grouping: issues) { issue in
        "\(issue.state.name) (\(issue.state.type ?? "nil"))"
    }
    return counts
        .map { key, value in "\(key)=\(value.count)" }
        .sorted()
        .joined(separator: ", ")
}

func linearWorkflowStateSummary(_ states: [LinearWorkflowState]) -> String {
    states
        .map { state in "\(state.name) (\(state.type ?? "nil")):\(state.id)" }
        .sorted()
        .joined(separator: ", ")
}

func linearDebugLog(_ message: String, environment: [String: String], homeDirectory: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let line = "\(timestamp) [pid:\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
    if let data = line.data(using: .utf8) {
        let directory = BanyanDataDirectory.fixtureDataHome(environment: environment)?
            .appendingPathComponent("Banyan", isDirectory: true)
            ?? URL(fileURLWithPath: homeDirectory, isDirectory: true)
                .appendingPathComponent("Library/Application Support/Banyan", isDirectory: true)
        let fileURL = directory.appendingPathComponent("linear-debug.log")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            NSLog("Banyan Linear file log failed: \(error.localizedDescription)")
        }
    }
    NSLog("Banyan Linear: %@", message)
}

enum LinearIssueLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
    case updating(String)
    case updatingDescription
}

enum LinearIssueClientError: Error {
    case authenticationUnavailable
    case commandUnavailable
    case issueNotFound
    case requestFailed
    case requestTimedOut
}
