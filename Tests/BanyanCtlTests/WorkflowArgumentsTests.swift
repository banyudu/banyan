import Foundation
import Testing
@testable import BanyanCtl

@Suite struct WorkflowArgumentsTests {
    @Test func mapsJobAndWakeFlagsWithoutChangingPromptText() throws {
        let text = "Continue original conversation.\nCheck the deployed version."
        let payload = try BanyanCtl(arguments: []).workflowPayload([
            "--id", "TASK-123", "--job-id", "job-a", "--revision", "4", "--wake-id", "wake-a", "--text", text
        ])
        #expect(payload["jobID"] == "job-a")
        #expect(payload["wakeID"] == "wake-a")
        #expect(payload["text"] == text)
        #expect(payload["job-id"] == nil)
    }

    @Test func sessionCatalogPreservesIndependentWorkflowState() {
        let row = UnifiedSessionCatalog.appRow(["id": "TASK-123", "status": "completed",
            "workflow": ["owner": "workit", "jobID": "job-a", "state": "waiting", "revision": 4]])
        let workflow = row["workflow"] as? [String: Any]
        #expect(row["status"] as? String == "completed")
        #expect(workflow?["state"] as? String == "waiting")
    }
}
