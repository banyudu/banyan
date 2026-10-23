import Combine
import Foundation
import Testing
@testable import Banyan
@testable import BanyanCore

@Suite @MainActor struct SessionProjectContextObservationTests {
    @Test func repeatedBranchRefreshDoesNotPublishUnchangedMetadata() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let host = HostRuntimeContext(environment: ["PATH": "/usr/bin:/bin"], homeDirectory: root, currentDirectory: root.path)
        let session = BanyanSession(id: "row", title: "Pinned title", cwd: root.path,
            command: "", status: .needInput, telemetry: banyanTestTelemetry, host: host)
        session.isTitlePinned = true
        func context(branch: String = "main", group: String = "project", degraded: Bool = false) -> SessionProjectContext {
            SessionProjectContext(project: "project", branch: branch, groupID: group, groupTitle: group,
                isGitWorktree: false, isDefaultBranch: branch == "main", gitLookupDegraded: degraded)
        }
        session.applyProjectContext(context())
        var publications = 0, historySignals = 0, persistenceSignals = 0
        let subscription = session.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        session.onHistoryRelevantChange = { historySignals += 1 }
        session.onDidChange = { persistenceSignals += 1 }

        for _ in 0..<20 { session.applyProjectContext(context()) }
        #expect(publications == 0)
        #expect(historySignals == 0)
        #expect(persistenceSignals == 0)

        // Real branch/group changes still invalidate the row and reach persistence.
        session.applyProjectContext(context(branch: "feature", group: "new-project"))
        #expect(session.displayBranch == "feature")
        #expect(session.projectGroupID == "new-project")
        #expect(publications > 0)
        #expect(historySignals > 0)
        #expect(persistenceSignals == 1)

        // A failed lookup retains the good context; repeated failures are quiet.
        session.applyProjectContext(context(degraded: true))
        #expect(session.displayBranch == "feature")
        #expect(session.projectGroupID == "new-project")
        #expect(session.displayContextDegraded)
        publications = 0; historySignals = 0; persistenceSignals = 0
        session.applyProjectContext(context(degraded: true))
        #expect(publications == 0)
        #expect(historySignals == 0)
        #expect(persistenceSignals == 0)

        session.applyProjectContext(context(branch: "feature", group: "new-project"))
        #expect(!session.displayContextDegraded)
        #expect(historySignals > 0)
        #expect(persistenceSignals == 1)
    }
}
