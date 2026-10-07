import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Kernel start time, rather than elapsed time or command text, identifies a PID.
public struct AgentProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
}

public struct AgentProcessSample: Sendable {
    public let identity: AgentProcessIdentity
    public let parentPID: Int32
    public let groupID: Int32
    public let sessionID: Int32
    public let userID: UInt32
    public let cpuNanoseconds: UInt64
    public let residentBytes: UInt64
    public let isStopped: Bool

    public init(identity: AgentProcessIdentity, parentPID: Int32, groupID: Int32,
                sessionID: Int32, userID: UInt32, cpuNanoseconds: UInt64, residentBytes: UInt64 = 0,
                isStopped: Bool = false) {
        self.identity = identity
        self.parentPID = parentPID
        self.groupID = groupID
        self.sessionID = sessionID
        self.userID = userID
        self.cpuNanoseconds = cpuNanoseconds
        self.residentBytes = residentBytes
        self.isStopped = isStopped
    }

    public static func read(pid: Int32) -> AgentProcessSample? {
        #if canImport(Darwin)
        var bsd = proc_bsdinfo()
        var task = proc_taskinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, Int32(MemoryLayout.size(ofValue: bsd))) == MemoryLayout.size(ofValue: bsd),
              proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, Int32(MemoryLayout.size(ofValue: task))) == MemoryLayout.size(ofValue: task),
              bsd.pbi_status != SZOMB else { return nil }
        let session = getsid(pid)
        guard session > 1 else { return nil }
        return AgentProcessSample(
            identity: AgentProcessIdentity(pid: pid, startSeconds: bsd.pbi_start_tvsec, startMicroseconds: bsd.pbi_start_tvusec),
            parentPID: Int32(bsd.pbi_ppid), groupID: Int32(bsd.pbi_pgid), sessionID: session,
            userID: bsd.pbi_uid, cpuNanoseconds: task.pti_total_user + task.pti_total_system,
            residentBytes: task.pti_resident_size, isStopped: bsd.pbi_status == SSTOP)
        #else
        // The GUI feature is macOS-only. Never fall back to rounded ps timestamps.
        return nil
        #endif
    }
}

public struct AgentFreezeTicket: Codable, Equatable, Sendable {
    public let root: AgentProcessIdentity
    public let agents: [AgentProcessIdentity]
    public let groups: [AgentProcessIdentity]
    public let members: [AgentProcessIdentity]
}

public enum AgentFreezeError: LocalizedError {
    case unsafe(String)
    public var errorDescription: String? {
        if case .unsafe(let reason) = self { return reason }
        return nil
    }
}

/// No PID/name heuristics are used at the signaling boundary. A plan includes
/// every group in the pane tree, so MCP children using job control are covered.
public enum AgentProcessFreezer {
    public static func snapshot(rootPID: Int32) throws -> [AgentProcessSample] {
        let rows = try ProcessTableSource.rowsForSignaling().filter { !$0.state.hasPrefix("Z") }
        var tree: Set<Int32> = [rootPID]
        var pending = [rootPID]
        let children = Dictionary(grouping: rows, by: \.parentPID)
        while let parent = pending.popLast() {
            for row in children[Int(parent)] ?? [] {
                let pid = Int32(row.pid)
                if tree.insert(pid).inserted { pending.append(pid) }
            }
        }
        // Missing/unreadable tree members are an unsafe sample, not zero CPU.
        let samples = try tree.map { pid in
            guard let sample = AgentProcessSample.read(pid: pid) else {
                throw AgentFreezeError.unsafe("Could not sample the complete agent process tree")
            }
            return sample
        }
        let groups = Set(samples.map(\.groupID))
        guard !rows.contains(where: { !tree.contains(Int32($0.pid)) && groups.contains(getpgid(Int32($0.pid))) }) else {
            throw AgentFreezeError.unsafe("Agent process group contains a process outside its pane")
        }
        return samples
    }

    public static func plan(root: AgentProcessIdentity, agentPIDs: Set<Int32>,
                            samples: [AgentProcessSample], protectedPID: Int32 = getpid(),
                            protectedGroup: Int32 = getpgrp(), userID: UInt32 = getuid()) throws -> AgentFreezeTicket {
        let rows = Dictionary(samples.map { ($0.identity.pid, $0) }, uniquingKeysWith: { first, _ in first })
        guard let anchor = rows[root.pid], anchor.identity == root,
              anchor.sessionID == root.pid, anchor.userID == userID else {
            throw AgentFreezeError.unsafe("Pane process identity changed or is not an isolated terminal session")
        }
        var tree: Set<Int32> = [root.pid]
        var pending = [root.pid]
        while let parent = pending.popLast() {
            for row in samples where row.parentPID == parent {
                if tree.insert(row.identity.pid).inserted { pending.append(row.identity.pid) }
            }
        }
        guard !agentPIDs.isEmpty, agentPIDs.isSubset(of: tree), !tree.contains(protectedPID) else {
            throw AgentFreezeError.unsafe("No verified agent process in the pane")
        }
        var agentTree = agentPIDs
        var agentPending = Array(agentPIDs)
        while let parent = agentPending.popLast() {
            for row in samples where row.parentPID == parent {
                if agentTree.insert(row.identity.pid).inserted { agentPending.append(row.identity.pid) }
            }
        }
        guard samples.filter({ agentTree.contains($0.identity.pid) }).allSatisfy({ $0.groupID != anchor.groupID }) else {
            throw AgentFreezeError.unsafe("Agent shares the tmux pane-root group; relaunch it with the current process host before freezing")
        }
        let agentGroups = Set(samples.filter { agentTree.contains($0.identity.pid) }.map(\.groupID))
        let members = samples.filter { tree.contains($0.identity.pid) && agentGroups.contains($0.groupID) }
        let groups = Set(members.map(\.groupID))
        guard !groups.contains(protectedGroup), !groups.contains(where: { $0 <= 1 }),
              members.allSatisfy({ $0.userID == userID && $0.sessionID == anchor.sessionID }),
              samples.filter({ groups.contains($0.groupID) }).allSatisfy({ tree.contains($0.identity.pid) }),
              groups.allSatisfy({ group in members.contains { $0.identity.pid == group && $0.groupID == group } }) else {
            throw AgentFreezeError.unsafe("Process group is shared, detached, or has no verifiable leader")
        }
        return AgentFreezeTicket(root: root, agents: members.filter { agentPIDs.contains($0.identity.pid) }.map(\.identity),
                                 groups: groups.sorted().compactMap { rows[$0]?.identity }, members: members.map(\.identity))
    }

    /// Reject new/exited/reused descendants and >1% of one core over the sample.
    public static func isQuiet(_ first: [AgentProcessSample], _ second: [AgentProcessSample],
                               ticket: AgentFreezeTicket, elapsed: TimeInterval) -> Bool {
        guard elapsed >= 1, elapsed.isFinite else { return false }
        let ids = Set(ticket.members.map(\.pid))
        let a = Dictionary(first.filter { ids.contains($0.identity.pid) }.map { ($0.identity.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let b = Dictionary(second.filter { ids.contains($0.identity.pid) }.map { ($0.identity.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var delta: Double = 0
        for identity in ticket.members {
            guard let before = a[identity.pid], let after = b[identity.pid],
                  before.identity == identity, after.identity == identity,
                  before.groupID == after.groupID, before.sessionID == after.sessionID,
                  after.cpuNanoseconds >= before.cpuNanoseconds else { return false }
            delta += Double(after.cpuNanoseconds - before.cpuNanoseconds)
        }
        return delta / (elapsed * 1_000_000_000) <= 0.01
    }

    public static func freeze(_ ticket: AgentFreezeTicket) throws {
        let fresh = try plan(root: ticket.root, agentPIDs: Set(ticket.agents.map(\.pid)), samples: snapshot(rootPID: ticket.root.pid))
        guard Set(fresh.members) == Set(ticket.members), fresh.groups == ticket.groups,
              fresh.agents.allSatisfy({ ticket.agents.contains($0) }) else {
            throw AgentFreezeError.unsafe("Agent process tree changed before freeze")
        }
        var stopped: [AgentProcessIdentity] = []
        do {
            for leader in ticket.groups {
                guard let row = AgentProcessSample.read(pid: leader.pid), row.identity == leader,
                      row.groupID == leader.pid, row.sessionID == ticket.root.pid,
                      kill(-leader.pid, SIGSTOP) == 0 else {
                    throw AgentFreezeError.unsafe("Could not stop verified agent process group")
                }
                stopped.append(leader)
            }
            let after = try plan(root: ticket.root, agentPIDs: Set(ticket.agents.map(\.pid)),
                                 samples: snapshot(rootPID: ticket.root.pid))
            guard Set(after.members) == Set(ticket.members), after.groups == ticket.groups else {
                throw AgentFreezeError.unsafe("Agent spawned or lost a process while groups were stopping")
            }
        } catch {
            // A partial STOP must never strand already stopped groups.
            try? unfreeze(AgentFreezeTicket(root: ticket.root, agents: ticket.agents, groups: stopped, members: ticket.members))
            throw error
        }
    }

    public static func unfreeze(_ ticket: AgentFreezeTicket) throws {
        try signalVerified(ticket, number: SIGCONT)
    }

    /// Closing/restarting owns all groups in a frozen ticket, including MCP
    /// groups which a terminal hangup alone may leave orphaned and running.
    public static func terminate(_ ticket: AgentFreezeTicket) throws {
        try unfreeze(ticket)
        try signalVerified(ticket, number: SIGTERM)
    }

    private static func signalVerified(_ ticket: AgentFreezeTicket, number: Int32) throws {
        guard ticket.root.pid > 1, ticket.root.pid != getpid(), ticket.root.pid != getpgrp() else {
            throw AgentFreezeError.unsafe("Refused to signal a protected terminal session")
        }
        var failed = false
        for leader in ticket.groups {
            guard leader.pid > 1, leader.pid != getpgrp(), leader.pid != getpid(),
                  leader.pid != ticket.root.pid else {
                throw AgentFreezeError.unsafe("Refused to signal a protected process group")
            }
            if let row = AgentProcessSample.read(pid: leader.pid), row.identity == leader,
               row.groupID == leader.pid, row.sessionID == ticket.root.pid, row.userID == getuid() {
                if kill(-leader.pid, number) != 0 && errno != ESRCH { failed = true }
            } else {
                // A group leader can exit while stopped (SIGKILL). Resume only
                // individually verified survivors, never a possibly reused PGID.
                for member in ticket.members {
                    guard member.pid > 1, member.pid != getpid(),
                          let row = AgentProcessSample.read(pid: member.pid), row.identity == member,
                          row.groupID != getpgrp(),
                          row.groupID == leader.pid, row.sessionID == ticket.root.pid,
                          row.userID == getuid() else { continue }
                    if kill(member.pid, number) != 0 && errno != ESRCH { failed = true }
                }
            }
        }
        if failed { throw AgentFreezeError.unsafe("Could not signal all verified processes; retry the operation") }
    }
}

extension AgentProcessIdentity: Hashable {}
