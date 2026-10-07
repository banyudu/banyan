import Foundation
import Testing
@testable import BanyanCore

private func process(_ pid: Int32, parent: Int32 = 100, group: Int32 = 100,
                     session: Int32 = 100, start: UInt64 = 42, cpu: UInt64 = 0,
                     user: UInt32 = 501) -> AgentProcessSample {
    AgentProcessSample(identity: .init(pid: pid, startSeconds: start, startMicroseconds: 123),
                       parentPID: parent, groupID: group, sessionID: session,
                       userID: user, cpuNanoseconds: cpu)
}

private let root = process(100, parent: 99)
private let agent = process(101, group: 101)
private let mcp = process(102, parent: 101, group: 102)

private func plan(_ rows: [AgentProcessSample], identity: AgentProcessIdentity = root.identity) throws -> AgentFreezeTicket {
    try AgentProcessFreezer.plan(root: identity, agentPIDs: [101], samples: rows,
                                protectedPID: 900, protectedGroup: 900, userID: 501)
}

@Test func agentFreezePlanIncludesMCPGroupsAndKernelStartIdentity() throws {
    let ticket = try plan([root, agent, mcp])
    #expect(ticket.groups.map(\.pid) == [101, 102])
    #expect(Set(ticket.members.map(\.pid)) == [101, 102])
    #expect(ticket.agents == [agent.identity])
    #expect(try JSONDecoder().decode(AgentFreezeTicket.self, from: JSONEncoder().encode(ticket)) == ticket)
}

@Test func agentFreezeRejectsPIDReuseSharedGroupsAndDetachedChildren() {
    #expect(throws: AgentFreezeError.self) { try plan([process(100, start: 43), agent]) }
    #expect(throws: AgentFreezeError.self) { try plan([root, agent, process(200, parent: 1, group: 101)]) }
    #expect(throws: AgentFreezeError.self) { try plan([root, process(101)]) }
    #expect(throws: AgentFreezeError.self) { try plan([root, agent, process(102, parent: 101, group: 200)]) }
    #expect(throws: AgentFreezeError.self) { try plan([root, agent, process(102, parent: 101, group: 102, session: 102)]) }
    #expect(throws: AgentFreezeError.self) { try plan([root, process(101, group: 101, user: 502)]) }
    #expect(throws: AgentFreezeError.self) { try plan([process(100, session: 99), agent]) }
    #expect(throws: AgentFreezeError.self) { try plan([root]) }
    #expect(throws: AgentFreezeError.self) {
        try AgentProcessFreezer.plan(root: root.identity, agentPIDs: [101], samples: [root, agent],
                                    protectedPID: 101, protectedGroup: 900, userID: 501)
    }
    #expect(throws: AgentFreezeError.self) {
        try AgentProcessFreezer.plan(root: root.identity, agentPIDs: [101], samples: [root, agent],
                                    protectedPID: 900, protectedGroup: 101, userID: 501)
    }
}

@Test func agentFreezeCPUIncludesMCPAndRejectsMissingReusedOrMovingProcesses() throws {
    let first = [root, agent, mcp]
    let ticket = try plan(first)
    #expect(AgentProcessFreezer.isQuiet(first, first, ticket: ticket, elapsed: 1))
    #expect(!AgentProcessFreezer.isQuiet(first, first, ticket: ticket, elapsed: 0.5))
    #expect(!AgentProcessFreezer.isQuiet(first, [root, agent], ticket: ticket, elapsed: 1))
    #expect(!AgentProcessFreezer.isQuiet(first, [root, agent, process(102, parent: 101, group: 102, start: 44)], ticket: ticket, elapsed: 1))
    #expect(!AgentProcessFreezer.isQuiet(first, [root, agent, process(102, parent: 101, group: 102, cpu: 30_000_000)], ticket: ticket, elapsed: 1))
    #expect(!AgentProcessFreezer.isQuiet(first, [root, process(101, group: 102), mcp], ticket: ticket, elapsed: 1))
}

@Test func agentInactivityPolicyProtectsFocusedVisibleBusyAndUnknownSessions() {
    for status in SessionStatus.allCases {
        let allowed = AgentInactivityPolicy.permitsSuspension(status: status, focused: false, visible: false, quietSeconds: 600, threshold: 60)
        #expect(allowed == [.idle, .needInput].contains(status))
    }
    #expect(!AgentInactivityPolicy.permitsSuspension(status: .idle, focused: true, visible: false, quietSeconds: 600, threshold: 60))
    #expect(!AgentInactivityPolicy.permitsSuspension(status: .idle, focused: false, visible: true, quietSeconds: 600, threshold: 60))
    #expect(!AgentInactivityPolicy.permitsSuspension(status: .idle, focused: false, visible: false, quietSeconds: 10, threshold: 60))
    #expect(!AgentInactivityPolicy.permitsSuspension(status: .idle, focused: false, visible: false, quietSeconds: .nan, threshold: 60))
}

@Test func agentInactivityPolicyAdaptsThresholdAndProbeCadence() {
    let normal = AgentInactivityPolicy.idleThreshold(minutes: 10, background: false, onBattery: false, sessionCount: 2)
    #expect(normal == 600)
    #expect(AgentInactivityPolicy.idleThreshold(minutes: 10, background: true, onBattery: true, sessionCount: 12) < normal)
    #expect(AgentInactivityPolicy.idleThreshold(minutes: -100, background: true, onBattery: true, sessionCount: 12) == 60)
    #expect(AgentInactivityPolicy.idleThreshold(minutes: .nan, background: false, onBattery: false, sessionCount: 1) == normal)
    #expect(AgentInactivityPolicy.probeInterval(threshold: 60) < AgentInactivityPolicy.probeInterval(threshold: normal))
}

@Test func agentFreezeRoutesAreDistinctFromFrontendParking() throws {
    for (path, route) in [("/freeze", ControlRoute.freeze), ("/unfreeze", .unfreeze)] {
        #expect(ControlRoute.resolve(method: "POST", path: path) == route)
        #expect(ControlRoute.resolve(method: "GET", path: path) == nil)
        #expect(throws: ControlValidationError.missingID) { try route.validate(ControlPayload(apiVersion: "v1")) }
        try route.validate(ControlPayload(apiVersion: "v1", id: "synthetic"))
    }
    #expect(ControlRoute.freeze != .suspend)
    #expect(ControlRoute.unfreeze != .resume)
}
