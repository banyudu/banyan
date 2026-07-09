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

struct LinearWorkflowState: Equatable, Identifiable {
    let id: String
    let name: String
    let type: String?
    let color: String?
    let position: Double?
}

struct LinearIssueLabel: Equatable, Identifiable {
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

struct LinearIssueSummary: Equatable, Identifiable {
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

enum LinearIssueLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
    case updating(String)
}

enum LinearIssueClient {
    static func fetchIssueList(cwd: String, limit: Int = 50) async throws -> [LinearIssueSummary] {
        let output = try await runCommand(
            [
                "linear",
                "issue",
                "query",
                "--all-teams",
                "--assignee",
                "self",
                "--state",
                "unstarted",
                "--state",
                "started",
                "--sort",
                "priority",
                "--limit",
                "\(limit)",
                "--json",
                "--no-pager"
            ],
            cwd: cwd,
            timeout: 12
        )
        return try decodeIssueListResponse(output)
    }

    static func fetchIssue(identifier: String, cwd: String) async throws -> LinearIssueDetails {
        do {
            return try await fetchIssueWithLinearCLI(identifier: identifier, cwd: cwd)
        } catch {
            do {
                return try await fetchIssueWithAPIKey(identifier: identifier)
            } catch {
                throw LinearIssueClientError.authenticationUnavailable
            }
        }
    }

    static func fetchIssueStatus(identifier: String, cwd: String) async throws -> LinearIssueStatusSnapshot {
        do {
            return try await fetchIssueStatusWithLinearCLI(identifier: identifier, cwd: cwd)
        } catch {
            do {
                return try await fetchIssueStatusWithAPIKey(identifier: identifier)
            } catch {
                throw LinearIssueClientError.authenticationUnavailable
            }
        }
    }

    static func updateIssueState(identifier: String, state: LinearWorkflowState, cwd: String) async throws {
        do {
            _ = try await runCommand(
                ["linear", "issue", "update", identifier, "--state", state.name],
                cwd: cwd,
                timeout: 12
            )
        } catch {
            try await updateIssueStateWithAPIKey(identifier: identifier, stateID: state.id)
        }
    }

    private static func fetchIssueWithLinearCLI(identifier: String, cwd: String) async throws -> LinearIssueDetails {
        let output = try await runCommand(
            [
                "linear",
                "api",
                issueQuery,
                "--variables-json",
                "{\"id\":\"\(identifier)\"}"
            ],
            cwd: cwd,
            timeout: 12
        )
        return try decodeIssueResponse(output)
    }

    private static func fetchIssueStatusWithLinearCLI(identifier: String, cwd: String) async throws -> LinearIssueStatusSnapshot {
        let output = try await runCommand(
            [
                "linear",
                "api",
                issueStatusQuery,
                "--variables-json",
                "{\"id\":\"\(identifier)\"}"
            ],
            cwd: cwd,
            timeout: 8
        )
        return try decodeIssueStatusResponse(output)
    }

    private static func fetchIssueWithAPIKey(identifier: String) async throws -> LinearIssueDetails {
        guard let apiKey = ProcessInfo.processInfo.environment["LINEAR_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            throw LinearIssueClientError.authenticationUnavailable
        }

        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(GraphQLRequest(query: issueQuery, variables: ["id": identifier]))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw LinearIssueClientError.requestFailed
        }
        return try decodeIssueResponse(String(decoding: data, as: UTF8.self))
    }

    private static func fetchIssueStatusWithAPIKey(identifier: String) async throws -> LinearIssueStatusSnapshot {
        guard let apiKey = ProcessInfo.processInfo.environment["LINEAR_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            throw LinearIssueClientError.authenticationUnavailable
        }

        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(GraphQLRequest(query: issueStatusQuery, variables: ["id": identifier]))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw LinearIssueClientError.requestFailed
        }
        return try decodeIssueStatusResponse(String(decoding: data, as: UTF8.self))
    }

    private static func updateIssueStateWithAPIKey(identifier: String, stateID: String) async throws {
        guard let apiKey = ProcessInfo.processInfo.environment["LINEAR_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            throw LinearIssueClientError.authenticationUnavailable
        }

        var request = URLRequest(url: URL(string: "https://api.linear.app/graphql")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(
            GraphQLRequest(
                query: updateStateMutation,
                variables: [
                    "id": identifier,
                    "stateId": stateID
                ]
            )
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw LinearIssueClientError.requestFailed
        }
        let payload = try JSONDecoder().decode(GraphQLMutationResponse.self, from: data)
        if payload.errors?.isEmpty == false || payload.data?.issueUpdate?.success != true {
            throw LinearIssueClientError.requestFailed
        }
    }

    private static func decodeIssueResponse(_ output: String) throws -> LinearIssueDetails {
        let payload = try JSONDecoder().decode(GraphQLIssueResponse.self, from: Data(output.utf8))
        if payload.errors?.isEmpty == false {
            throw LinearIssueClientError.requestFailed
        }
        guard let issue = payload.data?.issue else {
            throw LinearIssueClientError.issueNotFound
        }
        return issue.details
    }

    private static func decodeIssueListResponse(_ output: String) throws -> [LinearIssueSummary] {
        let payload = try JSONDecoder().decode(LinearIssueListResponse.self, from: Data(output.utf8))
        return payload.nodes.map(\.summary)
    }

    private static func decodeIssueStatusResponse(_ output: String) throws -> LinearIssueStatusSnapshot {
        let payload = try JSONDecoder().decode(GraphQLIssueStatusResponse.self, from: Data(output.utf8))
        if payload.errors?.isEmpty == false {
            throw LinearIssueClientError.requestFailed
        }
        guard let issue = payload.data?.issue else {
            throw LinearIssueClientError.issueNotFound
        }
        return issue.snapshot
    }

    private static func runCommand(
        _ arguments: [String],
        cwd: String,
        timeout: TimeInterval
    ) async throws -> String {
        try await Task.detached(priority: .utility) {
            try runCommandBlocking(arguments, cwd: cwd, timeout: timeout)
        }.value
    }

    private static func runCommandBlocking(
        _ arguments: [String],
        cwd: String,
        timeout: TimeInterval
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = processEnvironment()

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw LinearIssueClientError.commandUnavailable
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) != .success {
            process.terminate()
            _ = semaphore.wait(timeout: .now() + 0.5)
            throw LinearIssueClientError.requestFailed
        }

        guard process.terminationStatus == 0 else {
            throw LinearIssueClientError.requestFailed
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = cleanCommandOutput(String(decoding: data, as: UTF8.self))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw LinearIssueClientError.requestFailed
        }
        return output
    }

    private static func cleanCommandOutput(_ value: String) -> String {
        let pattern = #"\u{001B}\[[0-?]*[ -/]*[@-~]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..., in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: "")
    }

    private static func processEnvironment() -> [String: String] {
        let additions = [
            "\(NSHomeDirectory())/bin",
            "\(NSHomeDirectory())/.bun/bin",
            "\(NSHomeDirectory())/.local/bin",
            "\(NSHomeDirectory())/.cargo/bin",
            "\(NSHomeDirectory())/go/bin",
            "\(NSHomeDirectory())/.nix-profile/bin",
            "/nix/var/nix/profiles/default/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin"
        ]
        return AppProcessEnvironment.make(pathAdditions: additions)
    }

    private static let issueQuery = """
    query BanyanIssue($id: String!) {
      issue(id: $id) {
        id
        identifier
        title
        description
        url
        priority
        estimate
        updatedAt
        assignee { name }
        creator { name }
        team {
          name
          states {
            nodes {
              id
              name
              type
              color
              position
            }
          }
        }
        state {
          id
          name
          type
          color
          position
        }
        project { name }
        cycle { name number }
        labels { nodes { name color } }
        comments(first: 5) {
          nodes {
            id
            body
            createdAt
            updatedAt
            user { name }
          }
        }
        attachments(first: 5) {
          nodes {
            id
            title
            url
          }
        }
      }
    }
    """

    private static let updateStateMutation = """
    mutation BanyanUpdateIssueState($id: String!, $stateId: String!) {
      issueUpdate(id: $id, input: { stateId: $stateId }) {
        success
      }
    }
    """

    private static let issueStatusQuery = """
    query BanyanIssueStatus($id: String!) {
      issue(id: $id) {
        identifier
        updatedAt
        team {
          states {
            nodes {
              id
              name
              type
              color
              position
            }
          }
        }
        state {
          id
          name
          type
          color
          position
        }
      }
    }
    """
}

private enum LinearIssueClientError: Error {
    case authenticationUnavailable
    case commandUnavailable
    case issueNotFound
    case requestFailed
}

private struct GraphQLRequest: Encodable {
    let query: String
    let variables: [String: String]
}

private struct LinearIssueListResponse: Decodable {
    let nodes: [LinearIssueSummaryPayload]
}

private struct LinearIssueSummaryPayload: Decodable {
    let id: String
    let identifier: String
    let title: String
    let url: String
    let priority: Int?
    let priorityLabel: String?
    let updatedAt: String?
    let state: GraphQLState
    let assignee: GraphQLUser?
    let team: LinearIssueSummaryTeam?
    let project: GraphQLNamedValue?
    let cycle: GraphQLCycle?
    let labels: GraphQLConnection<GraphQLLabel>?

    var summary: LinearIssueSummary {
        let cycleName = cycle.flatMap { cycle -> String? in
            if let name = cycle.name, !name.isEmpty {
                return name
            }
            if let number = cycle.number {
                return "Cycle \(number)"
            }
            return nil
        }
        return LinearIssueSummary(
            id: id,
            identifier: identifier,
            title: title,
            url: url,
            priority: priority,
            priorityLabel: priorityLabel,
            updatedAt: updatedAt,
            state: state.workflowState,
            assigneeName: assignee?.name,
            teamKey: team?.key,
            teamName: team?.name,
            projectName: project?.name,
            cycleName: cycleName,
            labels: (labels?.nodes ?? []).map { LinearIssueLabel(name: $0.name, color: $0.color) }
        )
    }
}

private struct LinearIssueSummaryTeam: Decodable {
    let key: String?
    let name: String?
}

private struct GraphQLIssueResponse: Decodable {
    let data: GraphQLIssueData?
    let errors: [GraphQLError]?
}

private struct GraphQLIssueData: Decodable {
    let issue: GraphQLIssue?
}

private struct GraphQLIssueStatusResponse: Decodable {
    let data: GraphQLIssueStatusData?
    let errors: [GraphQLError]?
}

private struct GraphQLIssueStatusData: Decodable {
    let issue: GraphQLIssueStatus?
}

private struct GraphQLError: Decodable {
    let message: String?
}

private struct GraphQLMutationResponse: Decodable {
    let data: GraphQLMutationData?
    let errors: [GraphQLError]?
}

private struct GraphQLMutationData: Decodable {
    let issueUpdate: GraphQLMutationResult?
}

private struct GraphQLMutationResult: Decodable {
    let success: Bool
}

private struct GraphQLIssue: Decodable {
    let id: String
    let identifier: String
    let title: String
    let description: String?
    let url: String
    let priority: Int?
    let estimate: Double?
    let updatedAt: String?
    let assignee: GraphQLUser?
    let creator: GraphQLUser?
    let team: GraphQLTeam?
    let state: GraphQLState
    let project: GraphQLNamedValue?
    let cycle: GraphQLCycle?
    let labels: GraphQLConnection<GraphQLLabel>?
    let comments: GraphQLConnection<GraphQLComment>?
    let attachments: GraphQLConnection<GraphQLAttachment>?

    var details: LinearIssueDetails {
        let states = sortedWorkflowStates(team?.states?.nodes ?? [])
        let cycleName = cycle.flatMap { cycle -> String? in
            if let name = cycle.name, !name.isEmpty {
                return name
            }
            if let number = cycle.number {
                return "Cycle \(number)"
            }
            return nil
        }
        return LinearIssueDetails(
            id: id,
            identifier: identifier,
            title: title,
            description: description,
            url: url,
            priority: priority,
            estimate: estimate,
            updatedAt: updatedAt,
            state: state.workflowState,
            workflowStates: states,
            assigneeName: assignee?.name,
            creatorName: creator?.name,
            teamName: team?.name,
            projectName: project?.name,
            cycleName: cycleName,
            labels: (labels?.nodes ?? []).map { LinearIssueLabel(name: $0.name, color: $0.color) },
            comments: (comments?.nodes ?? []).map {
                LinearIssueComment(
                    id: $0.id,
                    body: $0.body,
                    createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt,
                    userName: $0.user?.name
                )
            },
            attachments: (attachments?.nodes ?? []).map {
                LinearIssueAttachment(id: $0.id, title: $0.title, url: $0.url)
            }
        )
    }
}

private struct GraphQLIssueStatus: Decodable {
    let identifier: String
    let updatedAt: String?
    let team: GraphQLTeam?
    let state: GraphQLState

    var snapshot: LinearIssueStatusSnapshot {
        LinearIssueStatusSnapshot(
            identifier: identifier,
            updatedAt: updatedAt,
            state: state.workflowState,
            workflowStates: sortedWorkflowStates(team?.states?.nodes ?? [])
        )
    }
}

private func sortedWorkflowStates(_ states: [GraphQLState]) -> [LinearWorkflowState] {
    states.map(\.workflowState)
        .sorted {
            switch ($0.position, $1.position) {
            case let (lhs?, rhs?):
                return lhs < rhs
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
}

private struct GraphQLUser: Decodable {
    let name: String?
}

private struct GraphQLTeam: Decodable {
    let name: String?
    let states: GraphQLConnection<GraphQLState>?
}

private struct GraphQLNamedValue: Decodable {
    let name: String?
}

private struct GraphQLCycle: Decodable {
    let name: String?
    let number: Int?
}

private struct GraphQLState: Decodable {
    let id: String
    let name: String
    let type: String?
    let color: String?
    let position: Double?

    var workflowState: LinearWorkflowState {
        LinearWorkflowState(id: id, name: name, type: type, color: color, position: position)
    }
}

private struct GraphQLLabel: Decodable {
    let name: String
    let color: String?
}

private struct GraphQLComment: Decodable {
    let id: String
    let body: String
    let createdAt: String?
    let updatedAt: String?
    let user: GraphQLUser?
}

private struct GraphQLAttachment: Decodable {
    let id: String
    let title: String
    let url: String
}

private struct GraphQLConnection<Node: Decodable>: Decodable {
    let nodes: [Node]
}
