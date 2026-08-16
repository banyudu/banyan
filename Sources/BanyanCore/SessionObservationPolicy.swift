import Foundation

public struct SessionObservationReconciliation: Sendable, Equatable {
    public let observation: SessionStatusObservation
    public let providerChanged: Bool
    public let modelChanged: Bool
    public let currentPathChanged: Bool
    public let runtimeStateChanged: Bool

    public init(
        observation: SessionStatusObservation,
        providerChanged: Bool,
        modelChanged: Bool,
        currentPathChanged: Bool,
        runtimeStateChanged: Bool
    ) {
        self.observation = observation
        self.providerChanged = providerChanged
        self.modelChanged = modelChanged
        self.currentPathChanged = currentPathChanged
        self.runtimeStateChanged = runtimeStateChanged
    }
}

/// Determines which persisted session fields a supervisor observation changes.
public enum SessionObservationPolicy {
    public static func reconcile(
        currentStatus: SessionStatus,
        currentTone: SessionTone,
        currentProvider: CodingAgentProvider?,
        currentModelID: String? = nil,
        currentPath: String,
        observation: SessionStatusObservation
    ) -> SessionObservationReconciliation? {
        guard currentStatus != .closed else { return nil }
        let providerChanged = currentProvider != observation.provider
        let modelChanged = currentModelID != observation.modelID
        let currentPathChanged = observation.currentPath.map { $0 != currentPath } ?? false
        let runtimeStateChanged = currentStatus != observation.status || currentTone != observation.tone
        guard providerChanged || modelChanged || currentPathChanged || runtimeStateChanged else { return nil }
        return SessionObservationReconciliation(
            observation: observation,
            providerChanged: providerChanged,
            modelChanged: modelChanged,
            currentPathChanged: currentPathChanged,
            runtimeStateChanged: runtimeStateChanged
        )
    }
}
