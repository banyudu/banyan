@testable import Banyan
import BanyanCore
import Foundation
import Testing

@MainActor
@Suite(.serialized) struct CommandPaletteProjectTests {
    @Test func projectsIncludeHiddenRowsAndDistinguishMatchingNames() async throws {
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
        #expect(projects.count == 2)
        #expect(Set(projects.map(\.id)) == [parent.projectGroupID, duplicateName.projectGroupID])
        #expect(items.allSatisfy { $0.title == "New Session in project" })
        #expect(Set(items.map(\.detail)).count == 2)
        #expect(items.contains { $0.detail?.hasPrefix(other.path + " · ") == true })
        #expect(items.allSatisfy { CommandPaletteView.matchScore("new project", item: $0) != nil })
        #expect(items.allSatisfy { CommandPaletteView.matchScore("project", item: $0) != nil })
        #expect(items.allSatisfy { CommandPaletteView.matchScore("new missing-project", item: $0) == nil })
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
