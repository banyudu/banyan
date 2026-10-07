import Foundation
import Testing
@testable import BanyanCore

@Test func codexFallbackQuotesExactIdentityDirectoryHomeAndSettings() throws {
    let binding = CodexThreadBinding(threadID: "thread-'original", cwd: "/tmp/work tree",
        settings: .init(model: "test-model", modelProvider: "custom", approvalPolicy: "untrusted",
            sandbox: "read-only", config: ["provider_options": .object(["name": .string("a'b"), "enabled": .bool(true)]),
                "values": .array([.integer(2), .string("value")])]), codexHome: "/tmp/private home")
    let command = try CodexCLIFallback.command(binding: binding)
    #expect(command.contains("'resume' 'thread-'\\''original'"))
    #expect(command.contains("'-C' '/tmp/work tree'"))
    #expect(command.contains("'CODEX_HOME=/tmp/private home'"))
    #expect(command.contains("'model_provider=\"custom\"'"))
    #expect(command.contains("'approval_policy=\"untrusted\"'"))
    #expect(command.contains("'sandbox_mode=\"read-only\"'"))
    #expect(command.contains("'provider_options={\"enabled\" = true, \"name\" = \"a'\\''b\"}'"))
    #expect(!command.contains("--last"))
    #expect(!command.contains("remote-control"))
    #expect(command.contains("'--no-daemon'"))
    #expect(CodingAgentProvider.detect(in: command) == .codex)
}

@Test func codexFallbackOnlyStartsWhenNoNativeStartWasAttempted() throws {
    let initial = CodexThreadBinding(cwd: "/tmp/project")
    #expect(!(try CodexCLIFallback.command(binding: initial)).contains("'resume'"))
    #expect(throws: CodexAppServerError.self) {
        try CodexCLIFallback.command(binding: .init(cwd: "/tmp/project", creationAttempted: true))
    }
    #expect(throws: CodexAppServerError.self) {
        try CodexCLIFallback.command(binding: .init(threadID: "thread", cwd: "/tmp/project",
            settings: .init(config: ["unsupported": .null])))
    }
}

@Test func codexBindingDecodesRowsFromBeforeRolloutProvenance() throws {
    let old = #"{"threadID":"original","cwd":"/tmp/project","creationAttempted":true,"settings":{"approvalPolicy":"on-request","sandbox":"workspace-write","config":{}}}"#
    let binding = try JSONDecoder().decode(CodexThreadBinding.self, from: Data(old.utf8))
    #expect(binding.threadID == "original")
    #expect(binding.codexHome == nil)
    #expect(binding.cliFallbackReason == nil)
}
