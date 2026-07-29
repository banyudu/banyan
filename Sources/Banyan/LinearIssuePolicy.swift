import Foundation

enum LinearIssuePolicy {
    static func mergedWorkflowStates(
        _ workflowStates: [LinearWorkflowState],
        issues: [LinearIssueSummary]
    ) -> [LinearWorkflowState] {
        var statesByID: [String: LinearWorkflowState] = [:]
        for state in workflowStates {
            statesByID[state.id] = state
        }
        for issue in issues {
            statesByID[issue.state.id] = issue.state
        }
        return statesByID.values.sorted {
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
}
