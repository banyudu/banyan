import AppKit
import BanyanCore
import Darwin
import Foundation
import Testing
@testable import Banyan

/// All processes, transcripts, homes and tmux sockets belong to disposable
/// fixtures. These tests never inspect or signal a user's agent.
@Suite(.serialized)
@MainActor
struct AgentDeepSuspendTests {
    @Test func unquotedAbsoluteExecutableResumesExactProviderInSamePane() async throws {
        let f = try await DeepSuspendFixture(provider: .codex, unquotedAbsoluteExecutable: true)
        defer { f.cleanup() }
        #expect(f.session.command.hasPrefix("/") && !f.session.command.contains("'"))
        let rows = ProcessTable.snapshot().descendants(of: f.pane.rootPID)
        let shell = try #require(rows.first(where: { $0.parentPID == f.pane.rootPID }))
        #expect(shell.commandName == "/bin/zsh" && shell.isSupportedAgentForFreezing)
        let innerHost = try #require(rows.first(where: { $0.parentPID == shell.pid && $0.isBanyanProcessHost }))
        #expect(rows.contains { $0.pid == Int(f.agentPID) && $0.parentPID == innerHost.pid })
        let shellIdentity = try #require(AgentProcessSample.read(pid: Int32(shell.pid))?.identity)
        let background = try #require(f.backgroundIdentity())
        try await f.store.deepSuspendAgent(id: f.session.id)
        #expect(AgentProcessSample.presence(of: try #require(f.session.suspendTicket).agent) == .exited)
        #expect(f.session.suspendTicket?.agent.pid == f.agentPID)
        #expect(f.session.suspendTicket?.disk.id == f.diskID)
        #expect(AgentProcessSample.read(pid: Int32(shell.pid))?.identity == shellIdentity)
        #expect(AgentProcessSample.read(pid: background.pid)?.identity == background)
        try await waitForPuckState { ProcessTable.snapshot().descendants(of: f.pane.rootPID).count == 2 }
        try f.store.deepResumeAgent(id: f.session.id)
        try await waitForPuckState(timeout: .seconds(10)) { !f.session.isDeepSuspended }
        #expect(f.backend.primaryPaneSnapshot(named: f.session.tmuxSessionName)?.paneID == f.pane.paneID)
        #expect(f.currentAgentPID() != f.agentPID)
        #expect(AgentProcessSample.read(pid: Int32(shell.pid))?.identity == shellIdentity)
        #expect(f.backend.readSuspendJournal(named: f.session.tmuxSessionName) == .absent)
        let receipt = try String(contentsOf: f.fixture.root.appendingPathComponent("resumed"), encoding: .utf8).components(separatedBy: "|")
        try #require(receipt.count == 4)
        #expect(receipt[0] == f.diskID && receipt[1] == "from-login" && receipt[3] == "True")
        #expect(PathDisplayName.canonicalPath(receipt[2]) == PathDisplayName.canonicalPath(f.fixture.project.path))
    }

    @Test func unquotedAbsoluteExecutableStillRefusesIndependentProvider() async throws {
        let f = try await DeepSuspendFixture(provider: .codex, mode: "independent-agent", shellBackground: true,
            unquotedAbsoluteExecutable: true)
        defer { f.cleanup() }
        let agent = try #require(AgentProcessSample.read(pid: f.agentPID)?.identity)
        let secondPID = try #require(Int32(String(contentsOf: f.fixture.root.appendingPathComponent("shell-background"), encoding: .utf8)))
        let second = try #require(AgentProcessSample.read(pid: secondPID)?.identity)
        let rows = ProcessTable.snapshot().descendants(of: f.pane.rootPID)
        #expect(Set(AgentDeepSuspend.deepestProviderProcesses(in: rows).map(\.pid)) == [Int(agent.pid), Int(second.pid)])
        await #expect(throws: (any Error).self) { try await f.store.deepSuspendAgent(id: f.session.id) }
        #expect(AgentProcessSample.read(pid: agent.pid)?.identity == agent)
        #expect(AgentProcessSample.read(pid: second.pid)?.identity == second)
        #expect(f.backend.readSuspendJournal(named: f.session.tmuxSessionName) == .absent)
    }

    @Test func claudeFreshQueryAllowsOnlyOwnedBridgeHelperTurnover() async throws {
        let f = try await DeepSuspendFixture(provider: .claude, mode: "helper-turnover")
        defer { f.cleanup() }
        try await f.store.deepSuspendAgent(id: f.session.id)
        #expect(AgentProcessSample.read(pid: f.agentPID) == nil)
        let helpers = try String(contentsOf: f.fixture.root.appendingPathComponent("bridge-helper-pids"), encoding: .utf8)
            .split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        #expect(helpers.count >= 3 && Set(helpers).count == helpers.count)
        try await waitForPuckState { ProcessTable.snapshot().descendants(of: f.pane.rootPID).count == 2 }
        try f.store.deepResumeAgent(id: f.session.id)
        try await waitForPuckState(timeout: .seconds(10)) { !f.session.isDeepSuspended }
        #expect(f.backend.primaryPaneSnapshot(named: f.session.tmuxSessionName)?.paneID == f.pane.paneID)
        #expect(f.backend.suspendTicket(named: f.session.tmuxSessionName) == nil)
    }

    @Test func claudeFreshQueryStillRefusesUnrelatedChildTurnover() async throws {
        let f = try await DeepSuspendFixture(provider: .claude, mode: "helper-turnover-extra")
        defer { f.cleanup() }
        let identity = try #require(AgentProcessSample.read(pid: f.agentPID)?.identity)
        let background = try #require(f.backgroundIdentity())
        await #expect(throws: (any Error).self) { try await f.store.deepSuspendAgent(id: f.session.id) }
        #expect(try String(contentsOf: f.fixture.root.appendingPathComponent("bridge-query-count"), encoding: .utf8) == "2")
        #expect(f.backgroundIdentity() != background)
        #expect(AgentProcessSample.read(pid: f.agentPID)?.identity == identity)
        #expect(f.backend.readSuspendJournal(named: f.session.tmuxSessionName) == .absent)
    }

    @Test(arguments: [CodingAgentProvider.claude, .opencode], ["busy", "switch", "unavailable"])
    func currentProviderBridgeRecheckedAfterQuietWait(provider: CodingAgentProvider, transition: String) async throws {
        let f = try await DeepSuspendFixture(provider: provider)
        defer { f.cleanup() }
        let identity = try #require(AgentProcessSample.read(pid: f.agentPID)?.identity)
        let firstReply = f.fixture.root.appendingPathComponent("bridge-first-reply.json")
        let pending = Task { try await f.store.deepSuspendAgent(id: f.session.id) }
        defer { pending.cancel() }
        // Synchronize on the actual first idle reply, then change only live
        // provider state. CPU/output/frontend status deliberately stay idle.
        try await waitForPuckState { FileManager.default.fileExists(atPath: firstReply.path) }
        let reply = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: firstReply)) as? [String: Any])
        #expect(reply["id"] as? String == f.diskID && reply["ready"] as? Bool == true)
        try Data(transition.utf8).write(to: f.fixture.root.appendingPathComponent("bridge-state"), options: .atomic)
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(try String(contentsOf: f.fixture.root.appendingPathComponent("bridge-query-count"), encoding: .utf8) == "2")
        #expect(f.session.status == .idle)
        #expect(AgentProcessSample.read(pid: f.agentPID)?.identity == identity)
        #expect(AgentProcessSample.read(pid: f.agentPID)?.isStopped == false)
        #expect(f.backend.readSuspendJournal(named: f.session.tmuxSessionName) == .absent)
        #expect(f.session.suspendTicket == nil && !f.session.isDeepSuspended)
    }

    @Test(arguments: [CodingAgentProvider.claude, .opencode])
    func currentProviderBridgeResumesWithNoHeldJSONL(provider: CodingAgentProvider) async throws {
        let f = try await DeepSuspendFixture(provider: provider, mode: "bridge-closed")
        defer { f.cleanup() }
        #expect(try AgentDeepSuspend.openTranscripts(pid: f.agentPID).isEmpty)
        try await f.store.deepSuspendAgent(id: f.session.id)
        #expect(AgentProcessSample.read(pid: f.agentPID) == nil)
        try await waitForPuckState { ProcessTable.snapshot().descendants(of: f.pane.rootPID).count == 2 }
        try f.store.deepResumeAgent(id: f.session.id)
        try await waitForPuckState(timeout: .seconds(10)) { !f.session.isDeepResuming }
        #expect(!f.session.isDeepSuspended, "\(f.session.deepSuspendError ?? "")")
        #expect(try AgentDeepSuspend.openTranscripts(pid: try #require(f.currentAgentPID())).isEmpty)
        #expect(f.backend.primaryPaneSnapshot(named: f.session.tmuxSessionName)?.paneID == f.pane.paneID)
    }

    @Test(arguments: [CodingAgentProvider.claude, .codex, .opencode])
    func agentOnlyTERMReclaimsRSSAndResumesExactIDInSamePane(provider: CodingAgentProvider) async throws {
        let f = try await DeepSuspendFixture(provider: provider)
        defer { f.cleanup() }
        let before = try #require(AgentProcessSample.read(pid: f.agentPID))
        #expect(before.residentBytes > 64 * 1024 * 1024)
        let background = try #require(f.backgroundIdentity())
        let capture = f.backend.captureVisibleText(paneID: f.pane.paneID, lineLimit: 60)
        try await f.store.deepSuspendAgent(id: f.session.id)
        #expect(f.session.isDeepSuspended)
        #expect(!f.session.isSuspended)
        #expect(AgentProcessSample.read(pid: f.agentPID) == nil) // address space gone, not swap or STOP
        #expect(AgentProcessSample.read(pid: background.pid)?.identity == background)
        #expect(AgentProcessSample.read(pid: background.pid)?.isStopped == false)
        let parked = try #require(f.backend.primaryPaneSnapshot(named: f.session.tmuxSessionName))
        #expect(parked.paneID == f.pane.paneID && parked.rootPID == f.pane.rootPID && !parked.isDead)
        #expect(f.backend.captureVisibleText(paneID: parked.paneID, lineLimit: 60).contains(capture.trimmingCharacters(in: .whitespacesAndNewlines)))
        let ticket = try #require(f.backend.suspendTicket(named: f.session.tmuxSessionName))
        #expect(ticket.disk.id == f.diskID)
        let reading = try await f.store.readPaneOutput(id: f.session.id, lines: nil)
        #expect(reading.isDeepSuspended && reading.prompt == nil && reading.observation == nil)
        try await waitForPuckState { ProcessTable.snapshot().descendants(of: parked.rootPID).count == 2 }
        // A shell exists, keeps cwd, and retains exports across repeated resumes.
        try f.backend.sendLiteral(paneID: parked.paneID, text: "export FIXTURE_RETAINED=survived")
        try f.backend.sendKeys(paneID: parked.paneID, keys: [.enter])
        try await Task.sleep(for: .milliseconds(100))
        f.store.selection.selectedSessionID = f.session.id // resume on focus
        #expect(f.session.isDeepResuming)
        await #expect(throws: (any Error).self) {
            _ = try await f.store.injectInput(id: f.session.id, keys: [], text: "unsafe during startup", submit: true)
        }
        try await waitForPuckState(timeout: .seconds(10)) { !f.session.isDeepResuming }
        #expect(!f.session.isDeepSuspended, "\(f.session.deepSuspendError ?? "")")
        #expect(f.backend.suspendTicket(named: f.session.tmuxSessionName) == nil)
        let receipt = try String(contentsOf: f.fixture.root.appendingPathComponent("resumed"), encoding: .utf8)
        let parts = receipt.components(separatedBy: "|")
        #expect(parts.count == 4)
        #expect(parts[0] == f.diskID && parts[1] == "survived" && parts[3] == "True")
        #expect(PathDisplayName.canonicalPath(parts[2]) == PathDisplayName.canonicalPath(f.fixture.project.path))
        let resumedPID = try #require(f.currentAgentPID())
        #expect(resumedPID != f.agentPID)
        #expect(AgentProcessSample.read(pid: resumedPID)?.residentBytes ?? 0 > 64 * 1024 * 1024)
        #expect(AgentProcessSample.read(pid: background.pid)?.identity == background)
        print("Synthetic deep suspend \(provider.rawValue): RSS \(before.residentBytes) -> 0; same pane \(parked.paneID), same provider ID, background retained")
    }

    @Test func focusedBusyUnresolvedAndFocusRaceNeverTerminate() async throws {
        let f = try await DeepSuspendFixture(provider: .codex)
        defer { f.cleanup() }
        let identity = try #require(AgentProcessSample.read(pid: f.agentPID)?.identity)
        f.store.selectedSessionID = f.session.id
        await #expect(throws: (any Error).self) { try await f.store.deepSuspendAgent(id: f.session.id) }
        f.store.selectedSessionID = nil
        f.session.status = .executing
        await #expect(throws: (any Error).self) { try await f.store.deepSuspendAgent(id: f.session.id) }
        f.session.status = .idle
        f.session.lastFreezeInteractionAt = .distantPast
        try FileManager.default.moveItem(at: f.transcript, to: f.transcript.appendingPathExtension("hidden"))
        await #expect(throws: (any Error).self) { try await f.store.deepSuspendAgent(id: f.session.id) }
        try FileManager.default.moveItem(at: f.transcript.appendingPathExtension("hidden"), to: f.transcript)
        let pending = Task { try await f.store.deepSuspendAgent(id: f.session.id) }
        try await Task.sleep(for: .milliseconds(200))
        f.store.selectedSessionID = f.session.id
        await #expect(throws: (any Error).self) { try await pending.value }
        #expect(AgentProcessSample.read(pid: f.agentPID)?.identity == identity)
        #expect(f.backend.suspendTicket(named: f.session.tmuxSessionName) == nil)
        f.store.selectedSessionID = nil
        let closing = Task { try await f.store.deepSuspendAgent(id: f.session.id) }
        try await Task.sleep(for: .milliseconds(200))
        f.session.terminate()
        await #expect(throws: (any Error).self) { try await closing.value }
        #expect(f.backend.suspendTicket(named: f.session.tmuxSessionName) == nil)
        #expect(AgentProcessSample.read(pid: f.agentPID)?.identity == identity)
    }

    @Test func ignoredTERMDoesNotClaimReclamationAndFailedResumeKeepsRecovery() async throws {
        let ignored = try await DeepSuspendFixture(provider: .codex, mode: "ignore")
        defer { ignored.cleanup() }
        await #expect(throws: (any Error).self) { try await ignored.store.deepSuspendAgent(id: ignored.session.id) }
        #expect(ignored.session.isDeepTerminating)
        #expect(AgentProcessSample.read(pid: ignored.agentPID) != nil)
        #expect(ignored.backend.suspendTicket(named: ignored.session.tmuxSessionName)?.phase == .terminating)

        let failed = try await DeepSuspendFixture(provider: .claude, mode: "fail-resume")
        defer { failed.cleanup() }
        try await failed.store.deepSuspendAgent(id: failed.session.id)
        try await waitForPuckState { ProcessTable.snapshot().descendants(of: failed.pane.rootPID).count == 2 }
        try failed.store.deepResumeAgent(id: failed.session.id)
        try await waitForPuckState(timeout: .seconds(12)) { !failed.session.isDeepResuming }
        #expect(failed.session.isDeepSuspended)
        #expect(failed.session.deepSuspendError != nil)
        #expect(failed.backend.suspendTicket(named: failed.session.tmuxSessionName)?.disk.id == failed.diskID)
    }

    @Test func journalRestoresAfterFrontendLossAndBusyShellRefusesResume() async throws {
        let f = try await DeepSuspendFixture(provider: .codex)
        defer { f.cleanup() }
        try await f.store.deepSuspendAgent(id: f.session.id)
        f.session.suspendTicket = nil
        f.session.isDeepSuspended = false
        f.session.hasLoadedDeepSuspendTicket = false
        f.session.restoreDeepSuspendTicket()
        #expect(f.session.isDeepSuspended)
        try await waitForPuckState { ProcessTable.snapshot().descendants(of: f.pane.rootPID).count == 2 }
        try f.backend.sendLiteral(paneID: f.pane.paneID, text: "sleep 10")
        try f.backend.sendKeys(paneID: f.pane.paneID, keys: [.enter])
        try await waitForPuckState { ProcessTable.snapshot().descendants(of: f.pane.rootPID).count > 2 }
        #expect(throws: AgentFreezeError.self) { try f.store.deepResumeAgent(id: f.session.id) }
        #expect(f.backend.suspendTicket(named: f.session.tmuxSessionName) != nil)
    }

    @Test func delayedTERMRetainsRecoveryUntilExitAndWrongSessionNeverClearsIt() async throws {
        let delayed = try await DeepSuspendFixture(provider: .codex, mode: "delay")
        defer { delayed.cleanup() }
        await #expect(throws: (any Error).self) { try await delayed.store.deepSuspendAgent(id: delayed.session.id) }
        #expect(delayed.backend.suspendTicket(named: delayed.session.tmuxSessionName)?.phase == .terminating)
        #expect(delayed.session.isDeepTerminating)
        try await waitForPuckState(timeout: .seconds(6)) { !delayed.session.isDeepTerminating }
        #expect(AgentProcessSample.read(pid: delayed.agentPID) == nil)
        #expect(delayed.backend.suspendTicket(named: delayed.session.tmuxSessionName)?.disk.id == delayed.diskID)
        #expect(delayed.backend.suspendTicket(named: delayed.session.tmuxSessionName)?.phase == .suspended)

        let wrong = try await DeepSuspendFixture(provider: .claude, mode: "wrong-session")
        defer { wrong.cleanup() }
        try await wrong.store.deepSuspendAgent(id: wrong.session.id)
        try await waitForPuckState { ProcessTable.snapshot().descendants(of: wrong.pane.rootPID).count == 2 }
        try wrong.store.deepResumeAgent(id: wrong.session.id)
        try await waitForPuckState(timeout: .seconds(12)) { !wrong.session.isDeepResuming }
        #expect(wrong.session.isDeepSuspended)
        #expect(wrong.session.deepSuspendError != nil)
        #expect(wrong.backend.suspendTicket(named: wrong.session.tmuxSessionName)?.disk.id == wrong.diskID)
    }

    @Test func unknownProcessInspectionRetainsTerminatingRecoveryUntilExitIsProven() async throws {
        let f = try await DeepSuspendFixture(provider: .codex, mode: "delay")
        defer { f.cleanup() }
        f.session.deepProcessPresence = { _ in .unknown }
        await #expect(throws: (any Error).self) { try await f.store.deepSuspendAgent(id: f.session.id) }
        try await waitForPuckState(timeout: .seconds(6)) { AgentProcessSample.read(pid: f.agentPID) == nil }
        #expect(f.session.isDeepTerminating)
        #expect(f.backend.suspendTicket(named: f.session.tmuxSessionName)?.phase == .terminating)
        try f.store.deepResumeAgent(id: f.session.id)
        #expect(!f.session.isDeepResuming)
        #expect(f.currentAgentPID() == f.agentPID) // no command while exit is unknown
        f.session.deepProcessPresence = AgentProcessSample.presence
        try f.store.deepResumeAgent(id: f.session.id)
        try await waitForPuckState(timeout: .seconds(10)) { !f.session.isDeepSuspended }
        #expect(f.currentAgentPID() != f.agentPID)
    }

    @Test func shellOwnedBackgroundSurvivorDoesNotBlockSamePaneResume() async throws {
        let f = try await DeepSuspendFixture(provider: .codex, shellBackground: true)
        defer { f.cleanup() }
        let pidText = try String(contentsOf: f.fixture.root.appendingPathComponent("shell-background"), encoding: .utf8)
        let pid = try #require(Int32(pidText))
        let background = try #require(AgentProcessSample.read(pid: pid)?.identity)
        try await f.store.deepSuspendAgent(id: f.session.id)
        let ticket = try #require(f.session.suspendTicket)
        #expect(ticket.survivors.contains(background))
        try await Task.sleep(for: .milliseconds(200))
        try f.store.deepResumeAgent(id: f.session.id)
        try await waitForPuckState(timeout: .seconds(10)) { !f.session.isDeepResuming }
        #expect(!f.session.isDeepSuspended, "\(f.session.deepSuspendError ?? "")")
        #expect(AgentProcessSample.read(pid: pid)?.identity == background)
    }

    @Test func delayedReadinessRetryReconcilesExistingProcessAndCloseCancelsMonitors() async throws {
        let f = try await DeepSuspendFixture(provider: .codex, mode: "delayed-ready")
        defer { f.cleanup() }
        try await f.store.deepSuspendAgent(id: f.session.id)
        try await waitForPuckState { ProcessTable.snapshot().descendants(of: f.pane.rootPID).count == 2 }
        try f.store.deepResumeAgent(id: f.session.id)
        let startingFile = f.fixture.root.appendingPathComponent("starting-pid")
        try await waitForPuckState { (try? String(contentsOf: startingFile, encoding: .utf8)).flatMap(Int32.init) != nil }
        let startingPID = try #require(Int32(String(contentsOf: startingFile, encoding: .utf8)))
        try await waitForPuckState(timeout: .seconds(12)) { !f.session.isDeepResuming }
        #expect(f.session.isDeepSuspended)
        #expect(f.backend.suspendTicket(named: f.session.tmuxSessionName)?.phase == .resuming)
        try Data().write(to: f.fixture.root.appendingPathComponent("allow-ready"))
        try f.store.deepResumeAgent(id: f.session.id)
        try await waitForPuckState(timeout: .seconds(10)) { !f.session.isDeepResuming }
        #expect(!f.session.isDeepSuspended, "\(f.session.deepSuspendError ?? "")")
        #expect(f.currentAgentPID() == startingPID) // no second command

        let closed = try await DeepSuspendFixture(provider: .claude, mode: "delay")
        defer { closed.cleanup() }
        await #expect(throws: (any Error).self) { try await closed.store.deepSuspendAgent(id: closed.session.id) }
        closed.session.terminate()
        try await Task.sleep(for: .seconds(2))
        #expect(closed.session.status == .closed)
        #expect(closed.session.deepTerminationSource == nil)
        #expect(closed.backend.suspendTicket(named: closed.session.tmuxSessionName)?.phase == .terminating)
    }

    @Test func restoredJournalFailuresBlockInputUntilValidRecoveryAndCacheOnlySuccessfulAbsence() async throws {
        let f = try await DeepSuspendFixture(provider: .codex)
        defer { f.cleanup() }
        try await f.store.deepSuspendAgent(id: f.session.id)
        let ticket = try #require(f.backend.suspendTicket(named: f.session.tmuxSessionName))
        try await waitForPuckState { ProcessTable.snapshot().descendants(of: f.pane.rootPID).count == 2 }
        let fault = f.fixture.root.appendingPathComponent("fail-journal-read")
        let wrapper = f.fixture.root.appendingPathComponent("tmux-fault")
        let script = "#!/bin/sh\nfor argument do\nif [ \"$argument\" = '@banyan-deep-suspend' ] && [ -f "
            + AgentLaunchCommand.shellQuote(fault.path) + " ]; then exit 42; fi\ndone\nexec "
            + AgentLaunchCommand.shellQuote(f.backend.executableURL.path) + " \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        let flaky = TmuxBackend(executableURL: wrapper, workingDirectory: f.fixture.project.path,
            environment: ["PATH": "/usr/bin:/bin", "HOME": f.fixture.home.path, "LANG": "en_US.UTF-8"], socketName: f.backend.socketName)
        try Data().write(to: fault)
        f.fixture.persistence.save([f.session.persistenceSnapshot])
        let restoredStore = f.fixture.makeStore(tmuxBackend: f.backend, sessionBackend: flaky,
            processTable: DeepLiveProcessTable())
        restoredStore.loadPersistedSessionsIfNeeded()
        let restored = try #require(restoredStore.sessions.first as? TerminalSession)
        defer { restored.terminate() }
        await #expect(throws: (any Error).self) {
            _ = try await restoredStore.injectInput(id: restored.id, keys: [], text: "must never reach shell", submit: true)
        }
        #expect(restored.deepRecoveryIsUncertain && !restored.hasLoadedDeepSuspendTicket)
        #expect(f.backend.suspendTicket(named: restored.tmuxSessionName) == ticket)
        try FileManager.default.removeItem(at: fault)
        for malformed in ["{broken-json", ""] {
            let result = try SubprocessRunner.run(arguments: [f.backend.executableURL.path, "-L", f.backend.socketName,
                "set-option", "-t", restored.tmuxSessionName, "@banyan-deep-suspend", malformed],
                cwd: f.fixture.project.path, environment: ["PATH": "/usr/bin:/bin"], timeout: 4)
            #expect(result.terminationStatus == 0)
            await #expect(throws: (any Error).self) {
                _ = try await restoredStore.injectInput(id: restored.id, keys: [], text: "must never reach shell", submit: true)
            }
            #expect(restored.deepRecoveryIsUncertain && !restored.hasLoadedDeepSuspendTicket)
            if case .unavailable = f.backend.readSuspendJournal(named: restored.tmuxSessionName) {} else {
                Issue.record("Malformed/empty journal was treated as absence")
            }
        }
        #expect(!f.backend.captureVisibleText(paneID: f.pane.paneID, lineLimit: 30).contains("must never reach shell"))
        try f.backend.writeSuspendTicket(ticket, named: restored.tmuxSessionName)
        let recoveredPane = try #require(flaky.primaryPaneSnapshot(named: restored.tmuxSessionName))
        #expect(recoveredPane.paneID == ticket.paneID)
        #expect(AgentProcessSample.read(pid: Int32(recoveredPane.rootPID))?.identity == ticket.root)
        try restored.beginDeepResume()
        try await waitForPuckState(timeout: .seconds(10)) { !restored.isDeepResuming }
        #expect(!restored.isDeepSuspended && !restored.deepRecoveryIsUncertain)
        #expect(restored.suspendTicket == nil)

        let normal = f.restoredSession(backend: flaky)
        defer { normal.terminate() }
        try normal.beginDeepResume() // successful absence can be cached
        #expect(normal.hasLoadedDeepSuspendTicket)
        try Data().write(to: fault)
        #expect(throws: Never.self) { try normal.beginDeepResume() }
        #expect(!normal.isDeepSuspended)
    }

    @Test func recoveryInputGateAllowsTerminalProtocolReplies() {
        let view = DetectingLocalProcessTerminalView(frame: .zero)
        var attempts = 0
        view.permitsInput = { attempts += 1; return false }
        let data: [UInt8] = [27, 91, 49, 59, 49, 82]
        view.send(source: view, data: data[...])
        #expect(attempts == 1)
        view.send(source: view.getTerminal(), data: data[...])
        #expect(attempts == 1) // startup query reply bypasses the human-input gate
    }

    @Test func legacyOneShotLaunchWithPersistentFlagInCommandIsRefusedWithoutTERM() async throws {
        let f = try await DeepSuspendFixture(provider: .claude, legacy: true)
        defer { f.cleanup() }
        let identity = try #require(AgentProcessSample.read(pid: f.agentPID)?.identity)
        do {
            try await f.store.deepSuspendAgent(id: f.session.id)
            Issue.record("Legacy shell program must refuse deep suspension")
        } catch {
            #expect(error.localizedDescription.contains("Legacy one-shot pane"))
        }
        #expect(AgentProcessSample.read(pid: f.agentPID)?.identity == identity)
        #expect(f.backend.suspendTicket(named: f.session.tmuxSessionName) == nil)
    }

    @Test func retryReconcilesAnExitWhoseNotificationCouldNotCommit() async throws {
        let f = try await DeepSuspendFixture(provider: .codex)
        defer { f.cleanup() }
        try await f.store.deepSuspendAgent(id: f.session.id)
        try await waitForPuckState { ProcessTable.snapshot().descendants(of: f.pane.rootPID).count == 2 }
        // Persisted terminating state can outlive an exit notification when a
        // frontend/server connection fails between exit and journal commit.
        var ticket = try #require(f.session.suspendTicket)
        ticket.phase = .terminating
        try f.backend.writeSuspendTicket(ticket, named: f.session.tmuxSessionName)
        f.session.suspendTicket = ticket
        f.session.isDeepTerminating = true
        try f.store.deepResumeAgent(id: f.session.id)
        try await waitForPuckState(timeout: .seconds(10)) { !f.session.isDeepResuming }
        #expect(!f.session.isDeepSuspended && !f.session.isDeepTerminating)
        #expect(f.backend.suspendTicket(named: f.session.tmuxSessionName) == nil)
    }

    @Test(arguments: [CodingAgentProvider.claude, .codex, .opencode])
    func savedLaunchIDWithoutCurrentProcessProofNeverAuthorizesTERM(provider: CodingAgentProvider) async throws {
        let f = try await DeepSuspendFixture(provider: provider, mode: "no-proof")
        defer { f.cleanup() }
        let identity = try #require(AgentProcessSample.read(pid: f.agentPID)?.identity)
        await #expect(throws: (any Error).self) { try await f.store.deepSuspendAgent(id: f.session.id) }
        #expect(AgentProcessSample.read(pid: f.agentPID)?.identity == identity)
        #expect(f.backend.suspendTicket(named: f.session.tmuxSessionName) == nil)
    }

    @Test func storedLaunchAndCurrentThreadMismatchNeverAuthorizesTERM() async throws {
        let f = try await DeepSuspendFixture(provider: .codex, mode: "changed-thread")
        defer { f.cleanup() }
        let identity = try #require(AgentProcessSample.read(pid: f.agentPID)?.identity)
        await #expect(throws: (any Error).self) { try await f.store.deepSuspendAgent(id: f.session.id) }
        #expect(AgentProcessSample.read(pid: f.agentPID)?.identity == identity)
        #expect(f.backend.suspendTicket(named: f.session.tmuxSessionName) == nil)
    }

    @Test func heldCodexActiveTurnRefusesDespiteIdlePromptCPUAndFrontendStatus() async throws {
        let f = try await DeepSuspendFixture(provider: .codex)
        defer { f.cleanup() }
        let identity = try #require(AgentProcessSample.read(pid: f.agentPID)?.identity)
        let samples = try AgentProcessFreezer.snapshot(rootPID: Int32(f.pane.rootPID))
        let root = try #require(samples.first { $0.identity.pid == f.pane.rootPID })
        let shell = try #require(samples.first { $0.parentPID == root.identity.pid })
        let plan = try AgentProcessFreezer.plan(root: root.identity, agentPIDs: [f.agentPID], samples: samples)
        let prepared = AgentSuspendTicket(root: root.identity, shell: shell.identity, agent: identity, paneID: f.pane.paneID,
            disk: .init(provider: .codex, id: f.diskID, cwd: f.fixture.project.path), resumeCommand: "", residentBytes: 0,
            idleTranscriptPath: f.transcript.path)
        let file = try FileHandle(forWritingTo: f.transcript)
        defer { try? file.close() }
        for event in ["task_started", "user_message", "turn_aborted"] {
            try file.seekToEnd()
            try file.write(contentsOf: Data(("{\"type\":\"event_msg\",\"payload\":{\"type\":\"\(event)\"}}\n").utf8))
            f.session.status = .idle
            f.session.lastFreezeInteractionAt = .distantPast
            await #expect(throws: (any Error).self) { try await f.store.deepSuspendAgent(id: f.session.id) }
            // Also cover a turn beginning after preparation: the destructive
            // boundary rechecks the held rollout before delivering TERM.
            #expect(throws: CodexTUIHandoffError.self) { try AgentDeepSuspend.terminateAgent(prepared, freezePlan: plan) }
            #expect(AgentProcessSample.read(pid: f.agentPID)?.identity == identity)
            #expect(f.backend.suspendTicket(named: f.session.tmuxSessionName) == nil)
        }
    }

    @Test(arguments: [CodingAgentProvider.claude, .opencode])
    func unsupportedAdapterLeavesNormalAgentRunningAndRefusesTERM(provider: CodingAgentProvider) async throws {
        let f = try await DeepSuspendFixture(provider: provider, mode: "unsupported-adapter")
        defer { f.cleanup() }
        let identity = try #require(AgentProcessSample.read(pid: f.agentPID)?.identity)
        await #expect(throws: (any Error).self) { try await f.store.deepSuspendAgent(id: f.session.id) }
        #expect(AgentProcessSample.read(pid: f.agentPID)?.identity == identity)
        #expect(f.backend.suspendTicket(named: f.session.tmuxSessionName) == nil)
    }
}

@MainActor
private struct DeepSuspendFixture {
    let fixture: PuckStoreFixture
    let backend: TmuxBackend
    let store: SessionStore
    let session: TerminalSession
    let pane: TmuxPaneSnapshot
    let agentPID: Int32
    let diskID: String
    let transcript: URL

    init(provider: CodingAgentProvider, mode: String = "normal", shellBackground: Bool = false, legacy: Bool = false,
         unquotedAbsoluteExecutable: Bool = false) async throws {
        fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        diskID = provider == .opencode ? "ses_syntheticExactIdentity" : UUID().uuidString.lowercased()
        transcript = fixture.root.appendingPathComponent("transcript.jsonl")
        let executable = fixture.root.appendingPathComponent(provider.defaultExecutableName)
        try Self.script.write(to: executable, atomically: true, encoding: .utf8)
        try Self.script.write(to: fixture.root.appendingPathComponent("mcp-server.py"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let host = try #require([".build/debug/banyanctl", ".build/out/Products/Debug/banyanctl"]
            .map { package.appendingPathComponent($0).path }.first { FileManager.default.isExecutableFile(atPath: $0) })
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin", "LANG": "en_US.UTF-8", "TERM": "xterm-256color"]
        environment["HOME"] = fixture.home.path
        environment["SHELL"] = "/bin/sh"
        environment["BANYAN_PROCESS_HOST"] = host
        environment["BANYAN_TEST_ROOT"] = fixture.root.path
        environment["BANYAN_TEST_PROVIDER"] = provider.rawValue
        environment["BANYAN_TEST_ID"] = diskID
        environment["BANYAN_TEST_MODE"] = mode
        try "export FIXTURE_RETAINED=from-login\n".write(to: fixture.home.appendingPathComponent(".profile"), atomically: true, encoding: .utf8)
        if unquotedAbsoluteExecutable {
            environment["SHELL"] = "/bin/zsh"
            try "export FIXTURE_RETAINED=from-login\n".write(to: fixture.home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        }
        if shellBackground {
            environment["SHELL"] = "/bin/zsh"
            let backgroundCommand = mode == "independent-agent" ? executable.path : fixture.root.appendingPathComponent("mcp-server.py").path
            let script = "if [[ -z $BANYAN_SHELL_BACKGROUND ]]; then\nexport BANYAN_SHELL_BACKGROUND=1\n/usr/bin/python3 "
                + AgentLaunchCommand.shellQuote(backgroundCommand) + " background shell &!\nfi\n"
            try script.write(to: fixture.home.appendingPathComponent(".zprofile"), atomically: true, encoding: .utf8)
        }
        backend = TmuxBackend(environment: environment, workingDirectory: fixture.project.path,
            socketName: "banyan-deep-test-\(UUID().uuidString)")
        let history = SyntheticDeepHistory(transcript: transcript, provider: provider, id: diskID, cwd: fixture.project.path)
        store = fixture.makeStore(historyBackend: history, tmuxBackend: backend,
            processTable: DeepLiveProcessTable(), freezePreferences: try #require(UserDefaults(suiteName: backend.socketName)))
        let options = provider == .codex ? "--no-daemon resume" : provider == .claude ? "--session-id" : "--session"
        let literal = (unquotedAbsoluteExecutable ? executable.path : AgentLaunchCommand.shellQuote(executable.path)) + " " + options + " " + diskID
        let command = legacy ? "cd . && " + literal + " '--persistent'" : literal
        session = store.spawn(id: "synthetic-deep", title: "Synthetic deep suspend", cwd: fixture.project.path, command: command, select: false)
        let pidFile = fixture.root.appendingPathComponent("pid")
        try await waitForPuckState { (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(Int32.init) != nil }
        agentPID = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        pane = try #require(backend.primaryPaneSnapshot(named: session.tmuxSessionName))
        session.status = .idle
        session.lastFreezeInteractionAt = .distantPast
        try await Task.sleep(for: .seconds(2.1))
    }

    func currentAgentPID() -> Int32? {
        (try? String(contentsOf: fixture.root.appendingPathComponent("pid"), encoding: .utf8)).flatMap(Int32.init)
    }

    func restoredSession(backend: TmuxBackend) -> TerminalSession {
        TerminalSession(id: session.id, tmuxSessionName: session.tmuxSessionName,
            title: "Restored synthetic agent", cwd: fixture.project.path, command: session.command,
            status: .idle, isRestored: true, theme: .system, tmuxBackend: backend,
            telemetry: banyanTestTelemetry, host: HostRuntimeContext(
                environment: ["PATH": "/usr/bin:/bin", "HOME": fixture.home.path, "SHELL": "/bin/sh"],
                homeDirectory: fixture.home, currentDirectory: fixture.project.path))
    }

    func backgroundIdentity() -> AgentProcessIdentity? {
        guard let value = try? String(contentsOf: fixture.root.appendingPathComponent("background"), encoding: .utf8),
              let pid = Int32(value) else { return nil }
        return AgentProcessSample.read(pid: pid)?.identity
    }

    func cleanup() {
        session.deepResumeTask?.cancel()
        // Only this private socket and fixture-named processes are touched.
        let rows = ProcessTable.snapshot().descendants(of: pane.rootPID)
        let background = backgroundIdentity()
        backend.killSession(named: session.tmuxSessionName)
        for row in rows where row.arguments.contains(fixture.root.path) && row.pid != getpid() {
            if let sample = AgentProcessSample.read(pid: Int32(row.pid)), sample.userID == getuid() {
                _ = kill(sample.identity.pid, SIGKILL)
            }
        }
        if let background, AgentProcessSample.read(pid: background.pid)?.identity == background {
            _ = kill(background.pid, SIGKILL)
        }
        store.freezePreferences.removePersistentDomain(forName: backend.socketName)
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private static let script = #"""
    #!/usr/bin/python3
    import json, os, pathlib, signal, subprocess, sys, time, threading
    root = pathlib.Path(os.environ['BANYAN_TEST_ROOT'])
    provider = os.environ['BANYAN_TEST_PROVIDER']
    expected = os.environ['BANYAN_TEST_ID']
    if sys.argv[1:] == ['--version']:
        print('0.0.0' if os.environ['BANYAN_TEST_MODE'] == 'unsupported-adapter' else '2.1.286' if provider == 'claude' else '1.18.34')
        sys.exit(0)
    if len(sys.argv) > 1 and sys.argv[1] == 'background':
        os.setpgrp()
        if len(sys.argv) > 2: (root / 'shell-background').write_text(str(os.getpid()))
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        while True: time.sleep(1)
    resumed = (root / 'pid').exists()
    if resumed and os.environ['BANYAN_TEST_MODE'] == 'fail-resume': sys.exit(23)
    if expected not in sys.argv: sys.exit(24)
    if resumed:
        if os.environ['BANYAN_TEST_MODE'] == 'delayed-ready':
            (root / 'starting-pid').write_text(str(os.getpid()))
            print('\x1b[2J\x1b[HStarting provider...', flush=True)
            while not (root / 'allow-ready').exists(): time.sleep(.05)
        record = json.loads((root / 'transcript.jsonl').read_text().splitlines()[0])
        saved = record.get('sessionId') or record.get('payload', {}).get('id') or record.get('id')
        if saved != expected: sys.exit(25)
        (root / 'resumed').write_text(expected + '|' + os.environ.get('FIXTURE_RETAINED', '') + '|' + os.getcwd() + '|' + str(os.tcgetpgrp(0) == os.getpgrp()))
    else:
        record = {'sessionId': expected, 'cwd': os.getcwd()}
        if provider == 'codex': record = {'type': 'session_meta', 'payload': {'id': expected, 'cwd': os.getcwd()}}
        if provider == 'opencode': record = {'id': expected, 'cwd': os.getcwd()}
        (root / 'transcript.jsonl').write_text(json.dumps(record) + '\n')
        if provider == 'codex':
            with (root / 'transcript.jsonl').open('a') as output:
                output.write(json.dumps({'type': 'event_msg', 'payload': {'type': 'task_complete'}}) + '\n')
        child = subprocess.Popen([sys.executable, str(root / 'mcp-server.py'), 'background'], preexec_fn=os.setpgrp,
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        (root / 'background').write_text(str(child.pid))
    transcript = (root / 'transcript.jsonl').open()
    if os.environ['BANYAN_TEST_MODE'] in ('no-proof', 'changed-thread', 'bridge-closed'):
        transcript.close()
        if os.environ['BANYAN_TEST_MODE'] == 'changed-thread':
            switched = root / 'current-thread.jsonl'
            switched.write_text(json.dumps({'type': 'session_meta', 'payload': {'id': '00000000-0000-4000-8000-000000000099', 'cwd': os.getcwd()}}) + '\n')
            transcript = switched.open()
    if resumed and os.environ['BANYAN_TEST_MODE'] == 'wrong-session':
        wrong = root / 'wrong.jsonl'
        wrong.write_text(json.dumps({'sessionId': '00000000-0000-4000-8000-000000000099', 'cwd': os.getcwd()}) + '\n')
        wrong_transcript = wrong.open()
    memory = bytearray(b'x') * (96 * 1024 * 1024)
    bridge = os.environ.get('BANYAN_AGENT_IDENTITY_DIR')
    if bridge and os.environ['BANYAN_TEST_MODE'] not in ('no-proof', 'changed-thread'):
        def answer_queries():
            global child
            last = None
            count = 0
            while True:
                try:
                    if os.environ['BANYAN_TEST_MODE'].startswith('helper-turnover'):
                        helper = subprocess.Popen([os.environ['BANYAN_AGENT_IDENTITY_HOST'], '__provider-identity', 'wait', bridge, last or ''],
                                                  stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                        with (root / 'bridge-helper-pids').open('a') as output: output.write(str(helper.pid) + '\n')
                        output, error = helper.communicate(timeout=600)
                        if helper.returncode != 0: return
                        request = json.loads(output)
                    else:
                        request = json.loads((pathlib.Path(bridge) / 'request.json').read_text())
                    if request['pid'] == os.getpid() and request['nonce'] != last:
                        last = request['nonce']
                        count += 1
                        (root / 'bridge-query-count').write_text(str(count))
                        state = (root / 'bridge-state').read_text() if (root / 'bridge-state').exists() else ''
                        if state == 'unavailable': continue
                        if count == 2 and not resumed and os.environ['BANYAN_TEST_MODE'] == 'helper-turnover-extra':
                            child.terminate()
                            child.wait(timeout=2)
                            child = subprocess.Popen([sys.executable, str(root / 'mcp-server.py'), 'background'], preexec_fn=os.setpgrp,
                                                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                            (root / 'background').write_text(str(child.pid))
                        current = '00000000-0000-4000-8000-000000000099' if resumed and os.environ['BANYAN_TEST_MODE'] == 'wrong-session' else expected
                        if state == 'switch': current = 'ses_switchedAfterIdleReply' if provider == 'opencode' else '00000000-0000-4000-8000-000000000099'
                        response = dict(nonce=last, pid=os.getpid(), provider=provider, id=current, cwd=os.getcwd(), ready=state != 'busy')
                        (pathlib.Path(bridge) / (last + '.json')).write_text(json.dumps(response))
                        if count == 1: (root / 'bridge-first-reply.json').write_text(json.dumps(response))
                except (OSError, ValueError, KeyError): pass
                time.sleep(.02)
        threading.Thread(target=answer_queries, daemon=True).start()
    if os.environ['BANYAN_TEST_MODE'] == 'ignore': signal.signal(signal.SIGTERM, signal.SIG_IGN)
    if os.environ['BANYAN_TEST_MODE'] == 'delay':
        def delayed_exit(number, frame):
            time.sleep(4)
            sys.exit(0)
        signal.signal(signal.SIGTERM, delayed_exit)
    print('OpenAI Codex (v0.synthetic)\n' + ('Ask anything...' if provider == 'opencode' else '> '), flush=True)
    (root / 'pid').write_text(str(os.getpid()))
    for line in sys.stdin: print('received ' + line.strip(), flush=True)
    """#
}

private struct DeepLiveProcessTable: ProcessTableProvider {
    func snapshot() -> ProcessTable { .snapshot() }
}

private struct SyntheticDeepHistory: SessionHistoryBackend {
    let transcript: URL
    let provider: CodingAgentProvider
    let id: String
    let cwd: String
    func load(maxPerProvider limit: Int) -> [ImportedAgentSession] { [] }
    func resumeCandidates(cwd: String, provider: CodingAgentProvider?, maxFilesScanned: Int) -> [AgentResumeCandidate] {
        guard FileManager.default.fileExists(atPath: transcript.path) else { return [] }
        return [.init(provider: self.provider, sourceID: id, cwd: self.cwd, createdAt: Date(), updatedAt: Date())]
    }
    func sourceID(fromImportedSessionID id: String, provider: CodingAgentProvider) -> String? { nil }
    func resumeCommand(provider: CodingAgentProvider, sourceID: String, cwd: String, prompt: String?) -> String? { nil }
    func prepareTrimmedTranscript(provider: CodingAgentProvider, sourceID: String, cwd: String, transcriptURL: URL?) -> String? { nil }
}
