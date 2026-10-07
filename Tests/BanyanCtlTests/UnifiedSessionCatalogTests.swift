import Foundation
import Testing
@testable import BanyanCtl

@Test func unifiedCatalogPreservesNativeCodexAndFallbackProvenance() throws {
    let provenance: [String: Any] = ["threadID": "thread-original", "cwd": "/tmp/project",
        "settings": ["model": "test-model", "approvalPolicy": "on-request", "sandbox": "read-only"],
        "cliFallbackReason": "Unsupported server version"]
    let native = UnifiedSessionCatalog.appRow(["id": "native", "backend": "codex", "codex": provenance])
    let fallback = UnifiedSessionCatalog.appRow(["id": "fallback", "backend": "terminal", "codex": provenance])
    #expect(native["backend"] as? String == "codex")
    #expect(fallback["backend"] as? String == "tmux")
    for row in [native, fallback] {
        let binding = try #require(row["codex"] as? [String: Any])
        #expect(binding["threadID"] as? String == "thread-original")
        #expect(binding["cliFallbackReason"] as? String == "Unsupported server version")
    }
    #expect(UnifiedSessionCatalog.appRow(["backend": "puck"])["backend"] as? String == "puck")
    #expect(UnifiedSessionCatalog.appRow(["id": "legacy"])["backend"] as? String == "tmux")
}
