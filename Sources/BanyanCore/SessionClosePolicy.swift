import Foundation

/// Decides whether closing a session requires explicit confirmation.
public enum SessionClosePolicy {
    public static func requiresConfirmation(
        hasActiveChildren: Bool,
        status: SessionStatus,
        provider: CodingAgentProvider?
    ) -> Bool {
        hasActiveChildren
            || SessionLifecyclePolicy.isOngoingCodingAgentSession(
                status: status,
                provider: provider
            )
    }
}
