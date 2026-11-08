import BanyanCore
import Foundation
import Testing
@testable import Banyan

/// Approvals and file changes render from their structure, not raw JSON.
struct PuckApprovalPresentationTests {
    private static let changes = #"""
    {"type":"fileChange","id":"fc-1","status":"inProgress","changes":[
      {"path":"/Users/example/project/Sources/App.swift","kind":{"type":"update","move_path":null},
       "diff":"@@ -1,2 +1,2 @@\n import Foundation\n-let mode = 1\n+let mode = 2\n"},
      {"path":"/Users/example/project/README.md","kind":{"type":"add"},"diff":"# Project\nHello\n"}]}
    """#

    @Test func codexCommandApprovalShowsTheCommandDirectoryAndReason() {
        let pending = PuckPendingApproval(
            callID: "call-1", tool: "exec_command",
            arguments: #"{"threadId":"t","turnId":"u","itemId":"i","command":"/bin/zsh -lc 'make test'","cwd":"/Users/example/project","reason":"Run the suite"}"#,
            expiresAtMS: 0
        )
        let presentation = PuckApprovalPresentation(pending)
        #expect(presentation.kind == .command)
        #expect(presentation.command == "/bin/zsh -lc 'make test'")
        #expect(presentation.workingDirectory == "/Users/example/project")
        #expect(presentation.reason == "Run the suite")
        #expect(presentation.details == nil)
        #expect(presentation.title == "Would you like to run the following command?")
    }

    @Test func nativeCommandApprovalReadsItsCallArguments() {
        let pending = PuckPendingApproval(callID: "call-1", tool: "exec_command",
                                          arguments: #"{"cmd":["git","status"],"workdir":"/tmp"}"#, expiresAtMS: 0)
        let presentation = PuckApprovalPresentation(pending)
        #expect(presentation.command == "git status")
        #expect(presentation.workingDirectory == "/tmp")
    }

    @Test func codexFileChangeApprovalFindsTheDiffOnItsItem() throws {
        let tool = PuckToolActivity(callID: "fc-1", name: "apply_patch", arguments: Self.changes, state: .running)
        let pending = PuckPendingApproval(callID: "call-2", tool: "apply_patch",
                                          arguments: #"{"threadId":"t","turnId":"u","itemId":"fc-1","reason":null}"#,
                                          expiresAtMS: 0)
        let presentation = PuckApprovalPresentation(pending, tools: [tool], workspace: "/Users/example/project")
        #expect(presentation.kind == .fileChange)
        #expect(presentation.fileSummary == "2 files (+3 −1)")
        let diff = try #require(presentation.diff)
        #expect(diff.contains("diff --git a/Users/example/project/Sources/App.swift"))
        #expect(diff.contains("+let mode = 2"))
        #expect(diff.contains("+++ b/Users/example/project/README.md\n+# Project\n+Hello"))
        #expect(presentation.reason == nil)
    }

    @Test func nativeFreeformPatchIsShownAsItsPatchText() {
        let patch = "*** Begin Patch\n*** Update File: a.txt\n-old\n+new\n*** End Patch"
        let presentation = PuckApprovalPresentation(
            PuckPendingApproval(callID: "call-3", tool: "apply_patch", arguments: patch, expiresAtMS: 0))
        #expect(presentation.kind == .fileChange)
        #expect(presentation.diff == patch)
    }

    @Test func otherApprovalsDropRoutingIDs() throws {
        let presentation = PuckApprovalPresentation(PuckPendingApproval(
            callID: "call-4", tool: "webfetch",
            arguments: #"{"threadId":"t","itemId":"i","url":"https://example.com"}"#, expiresAtMS: 0))
        #expect(presentation.kind == .other)
        let details = try #require(presentation.details)
        #expect(details.contains("example.com"))
        #expect(!details.contains("threadId"))
    }

    @Test func fileChangeToolsRenderAsDiffsFromLiveItemsAndHistoryRows() throws {
        let live = PuckToolActivity(callID: "fc-1", name: "apply_patch", arguments: Self.changes, state: .succeeded)
        #expect(live.displayTitle == "2 files (+3 −1)")
        #expect(live.actionLabel == "Edited")
        #expect(live.displayOutput.hasPrefix("diff --git"))
        #expect(!live.showsArgumentDetails)

        let object = try #require(try JSONSerialization.jsonObject(with: Data(Self.changes.utf8)) as? [String: Any])
        let list = try JSONSerialization.data(withJSONObject: object["changes"]!)
        let history = PuckToolActivity(callID: "fc-1", name: "apply_patch",
                                       output: String(decoding: list, as: UTF8.self), state: .succeeded)
        #expect(history.displayOutput == live.displayOutput)
        #expect(history.preview?.language == .diff)
    }

    @Test func runningCommandsPreviewTheirNewestOutput() {
        let tool = PuckToolActivity(callID: "c1", name: "exec_command", output: "one\ntwo\nthree\nfour",
                                    state: .running)
        #expect(tool.preview?.lines == ["three", "four"])
        let done = PuckToolActivity(callID: "c1", name: "exec_command", output: "one\ntwo\nthree\nfour",
                                    state: .succeeded)
        #expect(done.preview?.lines == ["one", "two"])
    }
}
