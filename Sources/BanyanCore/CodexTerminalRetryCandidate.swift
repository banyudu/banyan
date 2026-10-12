import Foundation

public struct CodexTerminalRetryCandidate: Sendable, Equatable {
    public let paneID: String
    public let root: AgentProcessIdentity
    public let agent: AgentProcessIdentity
    public let prompt: CodexTerminalRetryPrompt

    public init(paneID: String, root: AgentProcessIdentity, agent: AgentProcessIdentity, prompt: CodexTerminalRetryPrompt) {
        self.paneID = paneID; self.root = root; self.agent = agent; self.prompt = prompt
    }

    public var failureID: String {
        "\(paneID):\(agent.pid):\(agent.startSeconds):\(agent.startMicroseconds):\(prompt.footprint)"
    }
}
