import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum AgentAdmissionPaneInspection: Sendable {
    case present(TmuxPaneSnapshot)
    case absent
    case unknown
}

public enum AgentAdmissionProcessInspection: Sendable {
    case running(AgentProcessIdentity?)
    case exited
    case unknown

    /// A failed libproc read is not evidence of exit. ESRCH or a different
    /// kernel start identity proves that the recorded process has ended.
    public static func inspect(pid: Int32, expected: AgentProcessIdentity?) -> Self {
        guard pid > 1 else { return .unknown }
        if let expected {
            switch AgentProcessSample.presence(of: expected) {
            case .exited: return .exited
            case .alive: return .running(expected)
            case .unknown: return .unknown
            }
        }
        if let sample = AgentProcessSample.read(pid: pid) {
            if let expected, sample.identity != expected { return .exited }
            return .running(sample.identity)
        }
        if kill(pid, 0) == -1 && errno == ESRCH { return .exited }
        return .unknown
    }

    /// The persistent pane's inner host waits for the CLI job to exit; its
    /// identity bounds that job even while the outer host/login shell survive.
    /// No command-name guess or absence of descendants proves completion.
    public static func persistentCommandIdentity(root: AgentProcessIdentity) -> AgentProcessIdentity? {
        guard AgentProcessSample.read(pid: root.pid)?.identity == root else { return nil }
        let rows = ProcessTable.snapshot().descendants(of: Int(root.pid))
        guard let outer = rows.first(where: { $0.pid == Int(root.pid) }), outer.isBanyanProcessHost,
              outer.argumentVector?.dropFirst(2).first == AgentProcessHost.persistentFlag else { return nil }
        let jobs = rows.filter { $0.isBanyanProcessHost && $0.argumentVector?.dropFirst(2).first == AgentProcessHost.inheritedFlag }
        guard jobs.count == 1, let job = jobs.first,
              let sample = AgentProcessSample.read(pid: Int32(job.pid)), sample.sessionID == root.pid else { return nil }
        return sample.identity
    }
}
