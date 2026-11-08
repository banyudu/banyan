import Foundation
import Testing
import PuckSwift

/// Turn input, denial feedback and the event fields a session UI renders.
@Suite("Turn input and live event contract", .serialized)
struct TurnInputTests {
    @Test func imageTurnsAndDenialReasonsUsePublicWireKeys() throws {
        let fixture = try SDKSocketFixture { peer, request in
            try peer.reply(request, result: ["started": true])
        }
        defer { fixture.stop() }
        let client = PuckDaemonClient(socketPath: fixture.path)
        try client.turn("fixture-session", prompt: "Describe it", images: ["/tmp/fixture/screen.png"])
        try client.turn("fixture-session", prompt: "Text only")
        try client.decide("fixture-session", callID: "call-1", decision: "deny", reason: "Use the fixture script")
        try client.decide("fixture-session", callID: "call-2", decision: "approve")

        let params = fixture.requests.compactMap { $0["params"] as? [String: Any] }
        #expect(fixture.requests.compactMap { $0["method"] as? String } ==
                ["session.turn", "session.turn", "session.decide", "session.decide"])
        #expect(params[0]["images"] as? [String] == ["/tmp/fixture/screen.png"])
        #expect(params[0]["prompt"] as? String == "Describe it")
        #expect(params[1]["images"] == nil)
        #expect(params[2]["reason"] as? String == "Use the fixture script")
        #expect(params[3]["reason"] == nil)
        #expect(fixture.failures.isEmpty)
    }

    @Test func imageSupportRequiresTheFeatureAndTheEngine() throws {
        var capabilities = sdkCapabilities()
        capabilities["features"] = ["paged_history", "turn_images"]
        capabilities["engine_capabilities"] = [
            ["engine": "codex", "owns_coding_loop": true, "replaces_builtin_tools": false,
             "exact_parked_recovery": false, "paged_history": "engine history",
             "adding_custom_tools": false, "image_input": true],
            ["engine": "native", "owns_coding_loop": false, "replaces_builtin_tools": true,
             "exact_parked_recovery": true, "paged_history": "native history",
             "adding_custom_tools": true, "image_input": false],
        ]
        let decoded = try JSONDecoder().decode(
            PuckCapabilities.self, from: JSONSerialization.data(withJSONObject: capabilities))
        #expect(decoded.acceptsImages(engine: "codex"))
        #expect(!decoded.acceptsImages(engine: "native"))

        let legacy = try JSONDecoder().decode(
            PuckCapabilities.self, from: JSONSerialization.data(withJSONObject: sdkCapabilities()))
        #expect(!legacy.acceptsImages(engine: "codex"))
    }

    @Test func inMemoryServicesRefuseImagesInsteadOfDroppingThem() throws {
        struct TextOnly: PuckDaemonService {
            func list() throws -> [PuckSessionSummary] { [] }
            func get(_ id: String) throws -> PuckSessionSummary { throw PuckDaemonError.rejected("none") }
            func create(id: String, provider: String, account: String?, model: String?,
                        workspace: String) throws -> PuckSessionSummary { throw PuckDaemonError.rejected("none") }
            func turn(_ id: String, prompt: String) throws {}
            func decide(_ id: String, callID: String, decision: String) throws {}
            func answer(_ id: String, callID: String, selections: [PuckQuestionSelection]) throws {}
            func plan(_ id: String) throws -> String? { nil }
            func reject(_ id: String, callID: String, reason: String) throws {}
            func history(_ id: String, cursor: String?, limit: Int) throws -> PuckHistoryPage {
                throw PuckDaemonError.rejected("none")
            }
            func watch() -> any PuckDaemonObservation { PuckDaemonClient(socketPath: "/tmp/none").watch() }
            func follow(_ id: String) -> AsyncThrowingStream<PuckSessionUpdate, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        #expect(throws: PuckDaemonError.self) {
            try TextOnly().turn("fixture-session", prompt: "", images: ["/tmp/fixture.png"])
        }
        try TextOnly().turn("fixture-session", prompt: "Text", images: [])
    }

    @Test func eventDecodingRetainsStableIdentityStatusUsageAndImages() throws {
        let event = try PuckSessionEvent([
            "cursor": 19,
            "data": [
                "event": "tool_result",
                "tool": "fixture-tool",
                "call_id": "call-stable",
                "output": "fixture output",
                "success": false,
                "truncated": true,
                "item_id": "item-stable",
                "history_ref": "history-stable",
                "turn_id": "turn-stable",
                "images": ["/tmp/fixture/one.png"],
                "usage": [
                    "usage": [
                        "reported_requests": 3, "unreported_requests": 1,
                        "input_tokens": 120, "output_tokens": 30,
                        "cached_input_tokens": 80, "cache_unreported_requests": 2,
                    ],
                    "last": ["inputTokens": 40, "outputTokens": 10, "cachedInputTokens": 20],
                ],
                "future_flag": true,
            ],
        ])

        #expect(event.itemID == "item-stable")
        #expect(event.historyRef == "history-stable")
        #expect(event.turnID == "turn-stable")
        #expect(event.success == false)
        #expect(event.truncated)
        #expect(event.images == ["/tmp/fixture/one.png"])
        #expect(event.usage?.total.inputTokens == 120)
        #expect(event.usage?.total.reportedRequests == 3)
        #expect(event.usage?.last?.inputTokens == 40)
        #expect(event.metadata["future_flag"] == "1")
        #expect(event.metadata["images"] == nil)
    }

    @Test func historyUserItemsCarryImagesWhenPresent() throws {
        let payload = Data("""
        {"session":"fixture-session","source":"engine","order":"desc","next_cursor":null,"items":[
          {"id":"codex-1","kind":"user","text":"What is this?","truncated":false,"turn_id":"t1",
           "images":["/tmp/fixture/attachments/one.png"]},
          {"id":"codex-2","kind":"reasoning","text":"**Looking**","truncated":false,"turn_id":"t1"}]}
        """.utf8)
        let page = try JSONDecoder().decode(PuckHistoryPage.self, from: payload)
        #expect(page.items[0].images == ["/tmp/fixture/attachments/one.png"])
        #expect(page.items[1].images == nil)
        var window = PuckHistoryWindow()
        window.replace(with: page)
        #expect(window.byteCount > 0)
    }
}
