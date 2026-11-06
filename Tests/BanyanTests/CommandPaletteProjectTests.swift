@testable import Banyan
import BanyanCore
import Foundation
import Testing

@MainActor
@Suite(.serialized) struct CommandPaletteProjectTests {
    @Test func projectsIncludeHiddenRowsAndRecentProjectsAndDistinguishMatchingNames() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
        defer { store.flushPendingSessionSaves() }
        let other = fixture.root.appendingPathComponent("other/project")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let parent = store.spawn(id: "parent", cwd: fixture.project.path, command: "", select: false)
        let child = store.spawn(id: "child", cwd: fixture.project.path, command: "",
            parentSessionID: parent.id, select: false)
        let duplicateName = store.spawn(id: "other", cwd: other.path, command: "", select: false)
        let closed = store.spawn(id: "closed", cwd: fixture.home.path, command: "", select: false)
        let imported = TerminalSession(id: "imported", title: "Imported", cwd: fixture.root.path, command: "",
            historyTranscriptURL: fixture.root.appendingPathComponent("history.jsonl"),
            theme: store.terminalTheme,
            tmuxBackend: AdmissionTerminalBackend(), telemetry: banyanTestTelemetry, host: store.host)
        store.sessions.append(imported)
        for session in store.sessions { session.status = .idle }
        closed.status = .closed
        store.selectedSessionID = nil
        store.sidebarScope = .focus
        store.foldedParentIDs = [parent.id]
        store.historyFilterText = "no match"

        let projects = await store.commandPaletteProjects()
        let items = store.projectCommandPaletteItems(for: projects)

        #expect(!store.sessionSidebarGroups.flatMap(\.items).contains { $0.id == child.id })
        #expect(projects.count == 3)
        #expect(Set(projects.map(\.id)) == [parent.projectGroupID, duplicateName.projectGroupID, closed.projectGroupID])
        let matchingNames = items.filter { $0.title == "New Session in project" }
        #expect(matchingNames.count == 2)
        #expect(Set(matchingNames.map(\.detail)).count == 2)
        #expect(items.contains { $0.detail?.hasPrefix(other.path + " · ") == true })
        #expect(matchingNames.allSatisfy { CommandPaletteView.matchScore("new project", item: $0) != nil })
        #expect(matchingNames.allSatisfy { CommandPaletteView.matchScore("project", item: $0) != nil })
        #expect(items.allSatisfy { CommandPaletteView.matchScore("new missing-project", item: $0) == nil })
    }

    @Test func recentProjectsSurviveCloseRemovalAndRestartAndCanLaunchAgain() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
        let previousAgent = store.paletteAgentProfileID
        defer {
            store.paletteAgentProfileID = previousAgent
            store.flushPendingSessionSaves()
        }
        let first = store.spawn(id: "first", cwd: fixture.project.path, command: "", select: false)
        let second = store.spawn(id: "second", cwd: fixture.home.path, command: "", select: false)
        store.selectedSessionID = first.id
        try store.close(id: first.id)
        let afterClose = await store.commandPaletteProjects()
        #expect(afterClose.contains { $0.id == first.projectGroupID })
        try store.remove(id: first.id)
        try store.remove(id: second.id)
        store.flushPendingSessionSaves()

        let restored = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
        defer {
            clearRememberedProjectLaunches(restored)
            restored.flushPendingSessionSaves()
        }
        #expect(restored.sessions.isEmpty)
        let projects = await restored.commandPaletteProjects()
        #expect(Set(projects.map(\.cwd)) == [fixture.project.path, fixture.home.path])
        let project = try #require(projects.first { $0.id == first.projectGroupID })
        restored.paletteAgentProfileID = nil
        let item = try #require(restored.projectCommandPaletteItems(for: [project]).first)
        item.action()
        #expect(restored.selectedSession?.cwd == fixture.project.path)
        #expect(restored.selectedSession?.parentSessionID == nil)
        #expect(await restored.commandPaletteProjects().filter { $0.id == project.id }.count == 1)
    }

    @Test func recentProjectsFollowSelectionOrderAndSkipMissingDirectories() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
        defer { store.flushPendingSessionSaves() }
        let first = store.spawn(id: "first", cwd: fixture.project.path, command: "", select: false)
        let second = store.spawn(id: "second", cwd: fixture.home.path, command: "", select: false)
        store.selectedSessionID = second.id
        store.selectedSessionID = first.id
        store.selectedSessionID = nil
        try store.remove(id: first.id)
        try store.remove(id: second.id)
        #expect(await store.commandPaletteProjects().map(\.cwd) == [fixture.project.path, fixture.home.path])
        try FileManager.default.removeItem(at: fixture.project)
        #expect(await store.commandPaletteProjects().map(\.cwd) == [fixture.home.path])
    }

    @Test func recentProjectHistoryRetainsTheThirtyMostRecentlyUsedProjects() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
        defer { store.flushPendingSessionSaves() }
        for index in 0..<32 {
            let directory = fixture.root.appendingPathComponent("project-\(index)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            store.recentProjectHistory.record(cwd: directory.path,
                usedAt: Date(timeIntervalSince1970: Double(index)))
        }
        let projects = await store.commandPaletteProjects()
        #expect(projects.map(\.title) == (2..<32).reversed().map { "project-\($0)" })
        #expect(fixture.persistence.loadRecentProjects()?.count == 30)
    }

    @Test func asyncDirectoryChangesRememberBothProjectsWithMatchingIdentities() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
        defer { store.flushPendingSessionSaves() }
        let session = store.spawn(id: "moving", cwd: fixture.project.path, command: "", select: false)
        session.updateCurrentDirectoryAsync(fixture.home.path)
        try await waitForPuckState { session.projectGroupID == "path:\(fixture.home.path)" }
        try store.remove(id: session.id)
        let projects = await store.commandPaletteProjects()
        #expect(Set(projects.map(\.cwd)) == [fixture.project.path, fixture.home.path])
        #expect(projects.allSatisfy { $0.id == "path:\($0.cwd)" })
    }

    @Test func recentWorktreeProjectKeepsMainRootAfterWorktreeIsRemoved() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        try git(["init", "-b", "main"], in: fixture.project)
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.com",
                 "commit", "--allow-empty", "-m", "Initial commit"], in: fixture.project)
        let worktree = fixture.root.appendingPathComponent("worktree")
        try git(["worktree", "add", "-b", "feature", worktree.path], in: fixture.project)
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
        defer { store.flushPendingSessionSaves() }
        let session = store.spawn(id: "worktree", cwd: worktree.path, command: "", select: false)
        try store.remove(id: session.id)
        store.flushPendingSessionSaves()
        try git(["worktree", "remove", worktree.path], in: fixture.project)

        let restored = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
        let projects = await restored.commandPaletteProjects()
        #expect(projects.count == 1)
        #expect(projects.first?.cwd == fixture.project.path)
        #expect(projects.first?.id == session.projectGroupID)
    }

    @Test func existingClosedSessionsSeedRecentProjectsOnlyOnce() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        try git(["init", "-b", "main"], in: fixture.project)
        let nested = fixture.project.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
        defer { store.flushPendingSessionSaves() }
        let session = TerminalSession(id: "old", title: "Old", cwd: nested.path, command: "",
            status: .closed, theme: store.terminalTheme, tmuxBackend: AdmissionTerminalBackend(),
            telemetry: banyanTestTelemetry, host: store.host)
        fixture.persistence.save([session.persistenceSnapshot])
        store.loadPersistedSessionsIfNeeded()
        let projects = await store.commandPaletteProjects()
        #expect(projects.count == 1)
        #expect(projects.first?.cwd == fixture.project.path)
        #expect(projects.first?.title == "project")
        #expect(projects.first?.id == "path:\(fixture.project.path)")
        try store.remove(id: "old")
        store.flushPendingSessionSaves()
        let restored = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
        restored.loadPersistedSessionsIfNeeded()
        #expect(await restored.commandPaletteProjects() == projects)
        restored.flushPendingSessionSaves()
    }

    @Test func projectActionLaunchesRememberedProfileAtWorktreeRootFromAnotherProject() async throws {
        let fixture = try PuckStoreFixture(daemon: FakePuckDaemon())
        try git(["init", "-b", "main"], in: fixture.project)
        try git(["-c", "user.name=Test", "-c", "user.email=test@example.com",
                 "commit", "--allow-empty", "-m", "Initial commit"], in: fixture.project)
        let worktree = fixture.root.appendingPathComponent("worktree")
        try git(["worktree", "add", "-b", "feature", worktree.path], in: fixture.project)
        let nested = worktree.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
        let previousAgent = store.paletteAgentProfileID
        defer {
            store.paletteAgentProfileID = previousAgent
            clearRememberedProjectLaunches(store)
            store.flushPendingSessionSaves()
        }
        let remembered = NewSessionLaunch(id: "custom", label: "Custom Agent", providerName: "claude",
            iconName: nil, command: "fixture-agent --profile custom")
        store.sessionLaunchProfiles = NewSessionLaunch.builtInDefaults + [remembered]
        store.paletteAgentProfileID = nil
        let target = store.spawn(id: "target", cwd: nested.path, command: "", parentSessionID: "parent", select: false)
        _ = store.spawn(id: "same-project", cwd: fixture.project.path, command: "", select: false)
        let outside = store.spawn(id: "outside", cwd: fixture.home.path, command: "",
            parentSessionID: "outside-parent")
        store.projectLaunchByGroup[target.projectGroupID] = remembered.id
        #expect(store.selectedSessionID == outside.id)

        let projects = await store.commandPaletteProjects()
        let project = try #require(projects.first { $0.id == target.projectGroupID })
        #expect(project.cwd == fixture.project.path)
        #expect(projects.filter { $0.id == target.projectGroupID }.count == 1)
        let item = try #require(store.projectCommandPaletteItems(for: [project]).first)
        #expect(item.detail == "\(fixture.project.path) · Custom Agent")
        item.action()

        let created = try #require(store.selectedSession)
        #expect(created.id != outside.id)
        #expect(created.cwd == fixture.project.path)
        #expect(created.command == remembered.command)
        #expect(created.parentSessionID == nil)
        #expect(store.projectLaunch(for: project.id).id == remembered.id)
    }

    @Test func explicitPuckProfileOverridesAutoAndBecomesTheProjectDefault() async throws {
        let daemon = FakePuckDaemon()
        let fixture = try PuckStoreFixture(daemon: daemon)
        let store = fixture.makeStore(sessionBackend: AdmissionTerminalBackend())
        let previousAgent = store.paletteAgentProfileID
        defer {
            store.paletteAgentProfileID = previousAgent
            clearRememberedProjectLaunches(store)
            store.flushPendingSessionSaves()
        }
        let puck = NewSessionLaunch(id: "custom-puck", label: "Custom Puck", providerName: "codex",
            iconName: nil, command: "", puck: .init(provider: "codex", model: "test-model", account: "test-account"))
        store.sessionLaunchProfiles = NewSessionLaunch.builtInDefaults + [puck]
        _ = store.spawn(id: "target", cwd: fixture.project.path, command: "", parentSessionID: "parent")
        let projects = await store.commandPaletteProjects()
        let project = try #require(projects.first)
        store.projectLaunchByGroup[project.id] = "missing-profile"
        store.paletteAgentProfileID = nil
        #expect(store.projectCommandPaletteItems(for: projects).first?.detail?.hasSuffix(" · zsh") == true)

        store.paletteAgentProfileID = puck.id
        let item = try #require(store.projectCommandPaletteItems(for: projects).first)
        #expect(item.detail?.hasSuffix(" · Custom Puck") == true)
        item.action()
        try await waitForPuckState { store.selectedSession?.backendKind == .puck }

        let creation = try #require(daemon.creations.first)
        #expect(creation.workspace == fixture.project.path)
        #expect(creation.provider == "codex")
        #expect(creation.model == "test-model")
        #expect(creation.account == "test-account")
        #expect(store.selectedSession?.parentSessionID == nil)
        #expect(store.projectLaunch(for: project.id).id == puck.id)
        store.paletteAgentProfileID = nil
        #expect(store.projectCommandPaletteItems(for: projects).first?.detail?.hasSuffix(" · Custom Puck") == true)
    }

    private func clearRememberedProjectLaunches(_ store: SessionStore) {
        var saved = UserDefaults.standard.dictionary(forKey: SessionStore.projectLaunchDefaultsKey) ?? [:]
        for session in store.sessions { saved.removeValue(forKey: session.projectGroupID) }
        UserDefaults.standard.set(saved, forKey: SessionStore.projectLaunchDefaultsKey)
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
