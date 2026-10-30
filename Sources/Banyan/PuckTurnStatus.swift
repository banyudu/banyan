import SwiftUI

/// The single status vocabulary the detail pane presents for a Puck session.
/// It is derived only from daemon updates: a pending ask wins over the
/// daemon's `parked` position because that is what the user must handle next.
enum PuckTurnPhase: Equatable {
    case running
    case waitingForApproval
    case waitingForAnswer
    case idle
    case parked
    case interrupted
    case hibernated
    case unknown(String)

    init(position: String?, hasPendingApproval: Bool, hasPendingQuestion: Bool) {
        if hasPendingApproval {
            self = .waitingForApproval
            return
        }
        if hasPendingQuestion {
            self = .waitingForAnswer
            return
        }
        switch position?.lowercased() {
        case "running": self = .running
        case "idle": self = .idle
        case "parked": self = .parked
        case "interrupted": self = .interrupted
        case "hibernated": self = .hibernated
        case let position?: self = .unknown(position)
        case nil: self = .idle
        }
    }

    var label: String {
        switch self {
        case .running: "Running"
        case .waitingForApproval: "Waiting for approval"
        case .waitingForAnswer: "Waiting for answer"
        case .idle: "Idle"
        case .parked: "Parked"
        case .interrupted: "Interrupted"
        case .hibernated: "Hibernated"
        case .unknown: "Unknown"
        }
    }

    var systemImage: String {
        switch self {
        case .running: "arrow.triangle.2.circlepath"
        case .waitingForApproval: "hand.raised.fill"
        case .waitingForAnswer: "questionmark.bubble.fill"
        case .idle: "checkmark.circle"
        case .parked: "pause.circle.fill"
        case .interrupted: "exclamationmark.octagon.fill"
        case .hibernated: "moon.zzz.fill"
        case .unknown: "questionmark.circle"
        }
    }

    var tint: Color {
        switch self {
        case .running: .blue
        case .waitingForApproval, .waitingForAnswer, .parked: .orange
        case .idle, .hibernated: .secondary
        case .interrupted: .red
        case .unknown: .secondary
        }
    }

    var help: String {
        switch self {
        case .running:
            "The agent is working. Stop the turn to send another message."
        case .waitingForApproval:
            "The turn is paused until you approve or deny the tool call."
        case .waitingForAnswer:
            "The turn is paused until you answer the question."
        case .idle:
            "The session is ready for a new message."
        case .parked:
            "The turn is parked. Review it or stop it before sending another message."
        case .interrupted:
            "The turn was interrupted. This session and its history remain available."
        case .hibernated:
            "The session is hibernated and remains available for a new message."
        case .unknown(let position):
            "puckd reported \(position)."
        }
    }

    var isTurnActive: Bool {
        switch self {
        case .running, .waitingForApproval, .waitingForAnswer, .parked: true
        case .idle, .interrupted, .hibernated, .unknown: false
        }
    }
}

extension PuckSession {
    var turnPhase: PuckTurnPhase {
        PuckTurnPhase(
            position: position,
            hasPendingApproval: pendingApproval != nil,
            hasPendingQuestion: pendingQuestion != nil
        )
    }

    var canCancelTurn: Bool {
        turnPhase.isTurnActive && !cancelInFlight
    }
}

struct PuckTurnStatusBadge: View {
    let phase: PuckTurnPhase

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: phase.systemImage)
                .font(.caption2.weight(.semibold))
            Text(phase.label)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(phase.tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(phase.isTurnActive ? phase.tint.opacity(0.10) : Color.clear, in: Capsule())
        .help(phase.help)
        .accessibilityLabel("Session status: \(phase.label)")
        .accessibilityIdentifier(AccessibilityID.puckTurnStatus)
    }
}
