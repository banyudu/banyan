import Foundation
import Testing
@testable import BanyanCore

@Test func snapshotBuildsItsLaunchRequestFromPersistedRuntimeFields() {
    let snapshot = SessionSnapshot(
        id: "snapshot-session",
        tmuxSessionName: nil,
        title: "Shell",
        reportedTitle: nil,
        cwd: "/tmp/project",
        command: "codex",
        status: .running,
        tone: .blue,
        createdAt: Date(timeIntervalSince1970: 100),
        updatedAt: Date(timeIntervalSince1970: 100)
    )

    #expect(snapshot.launchRequest.sessionName == "banyan-snapshot-session")
    #expect(snapshot.launchRequest.cwd == "/tmp/project")
    #expect(snapshot.launchRequest.command == "codex")
}
