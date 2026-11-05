import BanyanCore
import Foundation
import AppKit
import SwiftUI

struct SidebarSessionItem: Identifiable {
    let session: BanyanSession
    let depth: Int
    let titleOverride: String?
    let isHistory: Bool
    let isParent: Bool
    let isFolded: Bool
    let moveOptions: SessionSidebarMoveOptions

    init(
        session: BanyanSession,
        depth: Int,
        titleOverride: String? = nil,
        isHistory: Bool = false,
        isParent: Bool = false,
        isFolded: Bool = false,
        moveOptions: SessionSidebarMoveOptions = []
    ) {
        self.session = session
        self.depth = depth
        self.titleOverride = titleOverride
        self.isHistory = isHistory
        self.isParent = isParent
        self.isFolded = isFolded
        self.moveOptions = moveOptions
    }

    var id: String {
        session.id
    }
}

struct SidebarSessionGroup: Identifiable {
    let id: String
    let title: String
    let items: [SidebarSessionItem]
    let moveItems: [SessionSelectionItem]

    init(
        id: String,
        title: String,
        items: [SidebarSessionItem],
        moveItems: [SessionSelectionItem] = []
    ) {
        self.id = id
        self.title = title
        self.items = items
        self.moveItems = moveItems
    }
}

enum SidebarMode: String, CaseIterable, Identifiable {
    case sessions
    case work
    case linear

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sessions: return "Sessions"
        case .work: return "Work"
        case .linear: return "Issues"
        }
    }
}

enum LinearIssueListLoadState: Equatable {
    case idle
    case loading
    case loaded
    case failed(String)
    case starting(String)
}

struct HandoffJob: Equatable, Identifiable {
    let id: String
    let sessionID: String
    let title: String
    let cwd: String
    let startedAt: Date
}

struct PendingLinearDescriptionUpdate {
    let issueID: String
    let oldDescription: String?
    let newDescription: String
}

struct PuckTurnError: LocalizedError {
    let sessionID: String
    let message: String

    var errorDescription: String? {
        "Session \(sessionID) was created: \(message)"
    }
}

enum ControlError: LocalizedError {
    case notFound(String)
    case badRequest(String)
    /// The request is well-formed but the session is in a state that cannot serve
    /// it. Carries its own code so a caller can tell "parked" from "malformed"
    /// and say which it was.
    case conflict(code: String, message: String)

    var code: String {
        switch self {
        case .notFound: return "not_found"
        case .badRequest: return "bad_request"
        case .conflict(let code, _): return code
        }
    }

    var httpStatus: Int {
        switch self {
        case .notFound: return 404
        case .badRequest: return 400
        case .conflict: return 409
        }
    }

    var errorDescription: String? {
        switch self {
        case .notFound(let id): return "No session found for id '\(id)'"
        case .badRequest(let message): return message
        case .conflict(_, let message): return message
        }
    }
}
