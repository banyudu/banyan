import BanyanCore
import SwiftUI

struct AgentAdmissionBanner: View {
    @ObservedObject var session: BanyanSession
    @ObservedObject var store: SessionStore

    var body: some View {
        if let position = session.agentQueuePosition {
            VStack(alignment: .leading, spacing: 8) {
                Text("Queued #\(position) · \(store.agentAdmission.running.count)/\(store.maximumConcurrentAgents) agent slots in use")
                    .font(.headline)
                Text("Starts when a running command exits or a native turn finishes. Idle, parked, and frozen CLI agents still hold their slots.")
                    .font(.caption)
                HStack {
                    Button("Run Next") { store.prioritizeQueuedAgent(id: session.id) }
                    Button("Cancel Queued Work") { store.cancelQueuedAgent(id: session.id) }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
            .accessibilityIdentifier("session.\(session.id).agentQueue")
        } else if let terminal = session as? TerminalSession, let error = terminal.admissionInspectionError {
            HStack {
                Text(error).font(.caption)
                Button("Recheck") { store.reconcileAgentAdmission(id: session.id) }
            }
            .padding()
            .background(.regularMaterial)
        } else if session.agentLaunchQueue?.cancelled == true {
            HStack {
                Text("Agent launch cancelled")
                Button("Queue Again") { store.retryQueuedAgent(id: session.id) }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial)
        }
    }
}
