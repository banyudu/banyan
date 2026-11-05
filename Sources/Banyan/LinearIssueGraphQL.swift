import BanyanCore
import Foundation

struct GraphQLRequest: Encodable {
    let query: String
    let variables: [String: String]
}

struct GraphQLIssueListPageRequest: Encodable {
    let query: String
    let variables: GraphQLIssueListPageVariables
}

struct GraphQLIssueListPageVariables: Encodable {
    let after: String?
}

struct LinearIssueListPageResult {
    let issues: [LinearIssueSummary]
    let hasNextPage: Bool
    let endCursor: String?
}

struct GraphQLIssueListPageResponse: Decodable {
    let data: GraphQLIssueListPageData?
    let errors: [GraphQLError]?
}

struct GraphQLIssueListPageData: Decodable {
    let issues: GraphQLIssueListConnection
}

struct GraphQLIssueListConnection: Decodable {
    let nodes: [LinearIssueSummaryPayload]
    let pageInfo: GraphQLPageInfo
}

struct GraphQLPageInfo: Decodable {
    let hasNextPage: Bool
    let endCursor: String?
}

struct LinearIssueSummaryPayload: Decodable {
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

struct LinearIssueSummaryTeam: Decodable {
    let key: String?
    let name: String?
}

struct GraphQLIssueResponse: Decodable {
    let data: GraphQLIssueData?
    let errors: [GraphQLError]?
}

struct GraphQLIssueData: Decodable {
    let issue: GraphQLIssue?
}

struct GraphQLIssueStatusResponse: Decodable {
    let data: GraphQLIssueStatusData?
    let errors: [GraphQLError]?
}

struct GraphQLIssueStatusData: Decodable {
    let issue: GraphQLIssueStatus?
}

struct GraphQLWorkflowStatesResponse: Decodable {
    let data: GraphQLWorkflowStatesData?
    let errors: [GraphQLError]?
}

struct GraphQLWorkflowStatesData: Decodable {
    let teams: GraphQLConnection<GraphQLWorkflowStatesTeam>
}

struct GraphQLWorkflowStatesTeam: Decodable {
    let states: GraphQLConnection<GraphQLState>?
}

struct GraphQLError: Decodable {
    let message: String?
}

struct GraphQLMutationResponse: Decodable {
    let data: GraphQLMutationData?
    let errors: [GraphQLError]?
}

struct GraphQLMutationData: Decodable {
    let issueUpdate: GraphQLMutationResult?
}

struct GraphQLMutationResult: Decodable {
    let success: Bool
}

struct GraphQLIssue: Decodable {
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

struct GraphQLIssueStatus: Decodable {
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

func sortedWorkflowStates(_ states: [GraphQLState]) -> [LinearWorkflowState] {
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

struct GraphQLUser: Decodable {
    let name: String?
}

struct GraphQLTeam: Decodable {
    let name: String?
    let states: GraphQLConnection<GraphQLState>?
}

struct GraphQLNamedValue: Decodable {
    let name: String?
}

struct GraphQLCycle: Decodable {
    let name: String?
    let number: Int?
}

struct GraphQLState: Decodable {
    let id: String
    let name: String
    let type: String?
    let color: String?
    let position: Double?

    var workflowState: LinearWorkflowState {
        LinearWorkflowState(id: id, name: name, type: type, color: color, position: position)
    }
}

struct GraphQLLabel: Decodable {
    let name: String
    let color: String?
}

struct GraphQLComment: Decodable {
    let id: String
    let body: String
    let createdAt: String?
    let updatedAt: String?
    let user: GraphQLUser?
}

struct GraphQLAttachment: Decodable {
    let id: String
    let title: String
    let url: String
}

struct GraphQLConnection<Node: Decodable>: Decodable {
    let nodes: [Node]
}
