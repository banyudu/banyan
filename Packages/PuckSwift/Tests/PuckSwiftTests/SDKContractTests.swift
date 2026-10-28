import Foundation
import Testing
import PuckSwift
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// These fixtures speak the public socket protocol and do not import Banyan,
/// launch an engine, or use a user's daemon/storage root.
@Suite("Standalone Swift SDK contract", .serialized)
struct SDKContractTests {
    @Test func typedOptionsNegotiateAndPreserveControls() async throws {
        let fixture = try SDKSocketFixture { peer, request in
            switch request["method"] as? String {
            case "daemon.capabilities": try peer.reply(request, result: sdkCapabilities())
            case "session.create": try peer.reply(request, result: sdkSummary())
            default: throw SDKFixtureError.unexpectedMethod
            }
        }
        defer { fixture.stop() }
        var options = PuckSessionOptions(workspace: "/tmp/sdk-project")
        options.id = "fixture-session"
        options.engine = .native
        options.provider = "fixture-provider"
        options.account = "fixture-seat"
        options.model = "fixture-model"
        options.instructions = "Keep this instruction."
        options.settings.approval = .deny
        options.settings.sandbox = .readOnly
        options.settings.exec = false
        options.settings.fetch = false
        options.settings.search = false
        options.settings.maxIterations = 7
        options.settings.contextBytes = 2048
        let summary = try await PuckClient(socketPath: fixture.path).create(options)
        #expect(summary.id == "fixture-session")
        #expect(fixture.requests.compactMap { $0["method"] as? String } == ["daemon.capabilities", "session.create"])
        let params = try #require(fixture.requests.last?["params"] as? [String: Any])
        #expect(params["engine"] as? String == "native")
        #expect(params["workspace"] as? String == "/tmp/sdk-project")
        #expect(params["instructions"] as? String == "Keep this instruction.")
        #expect(params["account"] as? String == "fixture-seat")
        let settings = try #require(params["settings"] as? [String: Any])
        #expect(settings["approval"] as? String == "deny")
        #expect(settings["sandbox"] as? String == "read-only")
        #expect(settings["exec"] as? Bool == false)
        #expect(settings["fetch"] as? Bool == false)
        #expect(settings["search"] as? Bool == false)
        #expect(settings["max_iterations"] as? Int == 7)
        #expect(settings["context_bytes"] as? Int == 2048)
        #expect(fixture.failures.isEmpty)
    }

    @Test func incompatibleProtocolRefusesCreation() throws {
        let fixture = try SDKSocketFixture { peer, request in
            try peer.reply(request, result: sdkCapabilities(major: 99))
        }
        defer { fixture.stop() }
        do {
            _ = try PuckDaemonClient(socketPath: fixture.path).create(PuckSessionOptions(workspace: "/tmp/sdk-project"))
            Issue.record("Creation accepted an incompatible protocol")
        } catch PuckDaemonError.rejected(let message) {
            #expect(message.contains("99"))
        }
        #expect(fixture.requests.count == 1)
        #expect(fixture.requests.first?["method"] as? String == "daemon.capabilities")
    }

    @Test func typedCapabilitiesAndResourceFieldsDecode() async throws {
        let fixture = try SDKSocketFixture { peer, request in
            switch request["method"] as? String {
            case "daemon.capabilities": try peer.reply(request, result: sdkCapabilities())
            case "daemon.resources": try peer.reply(request, result: [
                "sessions": 300, "active": 2, "queued": 4, "parked": 1,
                "hibernated": 293, "workers": 1, "loaded_threads": 3,
                "active_limit": 5, "queue_limit": 9, "loaded_threads_per_account": 3,
                "loaded_threads_total": 6
            ])
            default: throw SDKFixtureError.unexpectedMethod
            }
        }
        defer { fixture.stop() }
        let client = PuckClient(socketPath: fixture.path)
        let capabilities = try await client.capabilities()
        #expect(capabilities.version.major == 2)
        #expect(capabilities.engines == [.codex, .native])
        #expect(capabilities.defaultEngine == .codex)
        #expect(capabilities.features.contains("paged_history"))
        let codex = try #require(capabilities.engineCapabilities?.first { $0.engine == .codex })
        #expect(codex.ownsCodingLoop)
        #expect(!codex.replacesBuiltinTools)
        #expect(!codex.exactParkedRecovery)
        #expect(!codex.addingCustomTools)
        #expect(codex.pagedHistory == "engine history")
        let resources = try await client.resources()
        #expect(resources.sessions == 300)
        #expect(resources.loadedThreads == 3)
        #expect(resources.activeLimit == 5)
        #expect(resources.queueLimit == 9)
        #expect(resources.loadedThreadsPerAccount == 3)
        #expect(resources.loadedThreadsTotal == 6)
    }

    @Test func historyRoundTripsOpaqueCursorAndStableItemIdentity() async throws {
        let fixture = try SDKSocketFixture { peer, request in
            let params = request["params"] as? [String: Any] ?? [:]
            let secondPage = params["cursor"] as? String == "opaque:item/50?revision=7"
            try peer.reply(request, result: [
                "session": "fixture-session", "source": "codex_thread", "order": "desc",
                "items": [["id": secondPage ? "item-older" : "item-newer", "turn_id": "turn-stable",
                           "kind": "assistant", "text": secondPage ? "older" : "newer", "truncated": false]],
                "next_cursor": secondPage ? NSNull() : "opaque:item/50?revision=7"
            ])
        }
        defer { fixture.stop() }
        let client = PuckClient(socketPath: fixture.path)
        let first = try await client.history("fixture-session", limit: 17)
        let second = try await client.history("fixture-session", cursor: first.nextCursor, limit: 17)
        #expect(first.items.first?.id == "item-newer")
        #expect(second.items.first?.id == "item-older")
        #expect(second.items.first?.turnID == "turn-stable")
        #expect(second.nextCursor == nil)
        #expect(fixture.requests.count == 2)
        let params = try #require(fixture.requests.last?["params"] as? [String: Any])
        #expect(params["cursor"] as? String == first.nextCursor)
        #expect(params["limit"] as? Int == 17)
    }

    @Test func invalidHistoryLimitsFailBeforeConnecting() throws {
        let client = PuckDaemonClient(socketPath: "/tmp/puck-sdk-no-listener.sock")
        for limit in [-1, 0, 101, Int.max] {
            do {
                _ = try client.history("fixture-session", limit: limit)
                Issue.record("Accepted history limit \(limit)")
            } catch PuckDaemonError.rejected(let message) {
                #expect(message.contains("1...100"))
            }
        }
    }

    @Test func transientDeltasSharingDurableCursorAreAllDelivered() throws {
        let fixture = try SDKSocketFixture { peer, request in
            try peer.reply(request, result: sdkAttached(cursor: 11))
            try peer.notify(cursor: 11, kind: "text_delta", text: "first", transient: true)
            try peer.notify(cursor: 11, kind: "text_delta", text: "second", transient: true)
            try peer.notify(cursor: 11, kind: "assistant_message", text: "duplicate durable")
            try peer.notify(cursor: 12, kind: "assistant_message", text: "complete")
        }
        defer { fixture.stop() }
        let client = PuckDaemonClient(socketPath: fixture.path)
        let (connection, _) = try client.attach("fixture-session")
        defer { connection.disconnect() }
        let first = try #require(try client.receive(connection, session: "fixture-session", after: 11))
        let second = try #require(try client.receive(connection, session: "fixture-session", after: 11))
        let duplicate = try #require(try client.receive(connection, session: "fixture-session", after: 11))
        let completed = try #require(try client.receive(connection, session: "fixture-session", after: 11))
        #expect(first.map(\.text) == ["first"])
        #expect(second.map(\.text) == ["second"])
        #expect(first.first?.transient == true)
        #expect(duplicate.isEmpty)
        #expect(completed.map(\.cursor) == [12])
        #expect(fixture.requests.count == 1)
    }

    @Test func liveGapReplaysDurablePagesAndSuppressesDuplicateNotification() throws {
        let fixture = try SDKSocketFixture { peer, request in
            switch request["method"] as? String {
            case "session.attach":
                try peer.reply(request, result: sdkAttached(cursor: 2))
                try peer.notify(cursor: 5, kind: "assistant_message", text: "five")
                try peer.notify(cursor: 5, kind: "assistant_message", text: "duplicate")
            case "session.events":
                let after = (request["params"] as? [String: Any])?["after"] as? Int
                let events = after == 2 ? [sdkEvent(3, text: "three")] : [sdkEvent(4, text: "four"), sdkEvent(5, text: "five")]
                try peer.reply(request, result: ["cursor": 5, "events": events])
            default: throw SDKFixtureError.unexpectedMethod
            }
        }
        defer { fixture.stop() }
        let client = PuckDaemonClient(socketPath: fixture.path)
        let (connection, _) = try client.attach("fixture-session", after: 2)
        defer { connection.disconnect() }
        let replay = try #require(try client.receive(connection, session: "fixture-session", after: 2))
        #expect(replay.map(\.cursor) == [3, 4, 5])
        #expect(replay.map(\.text) == ["three", "four", "five"])
        let duplicate = try #require(try client.receive(connection, session: "fixture-session", after: 5))
        #expect(duplicate.isEmpty)
        let replayRequests = fixture.requests.filter { $0["method"] as? String == "session.events" }
        #expect(replayRequests.compactMap { ($0["params"] as? [String: Any])?["after"] as? Int } == [2, 3])
    }

    @Test func reconnectUsesDurableAfterCursorAndDoesNotReplayCompletedEffects() throws {
        let fixture = try SDKSocketFixture { peer, request in
            let after = (request["params"] as? [String: Any])?["after"] as? Int ?? 0
            try peer.reply(request, result: sdkAttached(cursor: 7, events: after < 7 ? [sdkEvent(7, text: "completed tool result")] : []))
        }
        defer { fixture.stop() }
        let client = PuckDaemonClient(socketPath: fixture.path)
        let first = try client.attach("fixture-session")
        #expect(first.1.batch.events.map(\.cursor) == [7])
        first.0.disconnect()
        let second = try client.attach("fixture-session", after: 7)
        defer { second.0.disconnect() }
        #expect(second.1.batch.events.isEmpty)
        #expect(second.1.batch.cursor == 7)
        #expect((fixture.requests.last?["params"] as? [String: Any])?["after"] as? Int == 7)
        #expect(fixture.requests.allSatisfy { $0["method"] as? String == "session.attach" })
    }

    @Test func cancellingFollowDetachesWithoutCancellingTurn() async throws {
        let fixture = try SDKSocketFixture { peer, request in
            try peer.reply(request, result: sdkAttached(cursor: 0))
        }
        defer { fixture.stop() }
        let attached = DispatchSemaphore(value: 0)
        let task = Task {
            for try await update in PuckClient(socketPath: fixture.path).follow("fixture-session") {
                if case .attached = update { attached.signal() }
            }
        }
        defer { task.cancel() }
        #expect(await sdkWait(attached))
        task.cancel()
        try await task.value
        #expect(await sdkWait(fixture.detached))
        #expect(fixture.requests.compactMap { $0["method"] as? String } == ["session.attach"])
    }

    @Test func explicitCancelSuspendAndCompactAreSeparateOperations() async throws {
        let fixture = try SDKSocketFixture { peer, request in try peer.reply(request, result: ["ok": true]) }
        defer { fixture.stop() }
        let client = PuckClient(socketPath: fixture.path)
        try await client.cancel("fixture-session")
        try await client.suspend("fixture-session")
        try await client.compact("fixture-session")
        #expect(fixture.requests.compactMap { $0["method"] as? String } == ["session.cancel", "session.suspend", "session.compact"])
    }

    @Test func dashboardWatchRequestsSummariesWithoutTranscriptAttachment() async throws {
        let fixture = try SDKSocketFixture { peer, request in
            switch request["method"] as? String {
            case "session.watch": try peer.reply(request, result: ["watching": true])
            case "presence.away": try peer.reply(request, result: ["window_seconds": 300])
            case "session.list": try peer.reply(request, result: [sdkSummary()])
            default: throw SDKFixtureError.unexpectedMethod
            }
        }
        defer { fixture.stop() }
        let observer = PuckDaemonClient(socketPath: fixture.path).watch()
        defer { observer.cancel() }
        let snapshot = DispatchSemaphore(value: 0)
        let consumer = Task {
            for try await update in observer.updates {
                if case .snapshot(let sessions) = update {
                    #expect(sessions.map(\.id) == ["fixture-session"])
                    snapshot.signal()
                }
            }
        }
        defer { consumer.cancel() }
        #expect(await sdkWait(snapshot))
        let watches = fixture.requests.filter { $0["method"] as? String == "session.watch" }
        #expect(watches.count == 2)
        #expect(watches.allSatisfy { ($0["params"] as? [String: Any])?["summary_only"] as? Bool == true })
        #expect(!fixture.requests.contains { ["session.attach", "session.history", "session.events"].contains($0["method"] as? String ?? "") })
        observer.cancel()
        try await consumer.value
        #expect(fixture.failures.isEmpty)
    }

    @Test func pagedFollowLoadsDisplayHistoryAndRefreshesAfterTurnCompletion() async throws {
        let fixture = try SDKSocketFixture { peer, request in
            switch request["method"] as? String {
            case "session.attach":
                var attached = sdkAttached(cursor: 100)
                attached["history_api"] = true
                try peer.reply(request, result: attached)
                try peer.notify(cursor: 100, kind: "text_delta", text: "streaming", transient: true)
                try peer.notify(cursor: 101, kind: "turn_done", text: "finished")
                peer.closeSocket()
            case "session.history":
                try peer.reply(request, result: [
                    "session": "fixture-session", "source": "engine_history", "order": "desc",
                    "items": [["id": "engine-item-stable", "kind": "assistant", "text": "saved", "truncated": false]],
                    "next_cursor": "older-page"
                ])
            case "session.get": try peer.reply(request, result: sdkSummary())
            default: throw SDKFixtureError.unexpectedMethod
            }
        }
        defer { fixture.stop() }
        var historyPages = 0
        var liveText: [String] = []
        var summaries = 0
        for try await update in PuckClient(socketPath: fixture.path).follow("fixture-session") {
            switch update {
            case .attached(_, let replay): #expect(replay.isEmpty)
            case .history(let page):
                historyPages += 1
                #expect(page.items.first?.id == "engine-item-stable")
                #expect(page.nextCursor == "older-page")
            case .events(let events): liveText.append(contentsOf: events.compactMap(\.text))
            case .summary: summaries += 1
            }
        }
        #expect(historyPages == 2)
        #expect(liveText == ["streaming", "finished"])
        #expect(summaries == 1)
        #expect(!fixture.requests.contains { $0["method"] as? String == "session.events" })
        #expect(fixture.failures.isEmpty)
    }

    @Test func staleAskRejectionReachesCaller() async throws {
        let fixture = try SDKSocketFixture { peer, request in
            try peer.send(["jsonrpc": "2.0", "id": request["id"] ?? 1,
                           "error": ["code": -32000, "message": "stale approval: worker lost"]])
        }
        defer { fixture.stop() }
        do {
            try await PuckClient(socketPath: fixture.path).decide("fixture-session", callID: "old-call", decision: "approve")
            Issue.record("A stale approval was accepted")
        } catch PuckDaemonError.rejected(let message) {
            #expect(message == "stale approval: worker lost")
        }
        #expect(fixture.requests.count == 1)
    }

    @Test(arguments: [false, true]) func structuredServerErrorsPreserveCodeAndMessage(notificationReader: Bool) throws {
        let fixture = try SDKSocketFixture { peer, request in
            try peer.send(["jsonrpc": "2.0", "id": request["id"] ?? 1,
                           "error": ["code": -32000, "message": "outer error",
                                     "data": ["code": "not_found", "message": "fixture session disappeared"]]])
        }
        defer { fixture.stop() }
        let connection = try PuckDaemonConnection(socketPath: fixture.path)
        defer { connection.disconnect() }
        do {
            if notificationReader {
                try connection.sendRequest("presence.active")
                _ = try connection.nextNotification()
            } else {
                _ = try connection.request("session.get", params: ["session": "missing-session"])
            }
            Issue.record("The structured error was ignored")
        } catch PuckDaemonError.server(let error) {
            #expect(error.code == "not_found")
            #expect(error.message == "fixture session disappeared")
        }
    }

    @Test func pagedFollowRefreshesHistoryAfterLagWithoutTurnDone() async throws {
        let fixture = try SDKSocketFixture { peer, request in
            switch request["method"] as? String {
            case "session.attach":
                var attached = sdkAttached(cursor: 1)
                attached["history_api"] = true
                try peer.reply(request, result: attached)
                try peer.notify(cursor: 0, kind: "lagged", text: "")
                peer.closeSocket()
            case "session.events": try peer.reply(request, result: ["cursor": 2, "events": [sdkEvent(2, text: "recovered")]])
            case "session.history":
                try peer.reply(request, result: ["session": "fixture-session", "source": "engine_history", "order": "desc", "items": [], "next_cursor": NSNull()])
            default: throw SDKFixtureError.unexpectedMethod
            }
        }
        defer { fixture.stop() }
        var historyPages = 0
        var recovered: [UInt64] = []
        for try await update in PuckClient(socketPath: fixture.path).follow("fixture-session") {
            if case .history = update { historyPages += 1 }
            if case .events(let events) = update {
                recovered.append(contentsOf: events.filter { $0.kind != "lagged" }.map(\.cursor))
                #expect(events.filter { $0.kind == "lagged" }.allSatisfy { $0.displayText == nil })
            }
        }
        #expect(historyPages == 2)
        #expect(recovered == [2])
    }

    @Test func historyWindowPagesOlderAndEvictsInBothDirections() {
        var window = PuckHistoryWindow(maxItems: 3, maxBytes: 4096)
        window.replace(with: sdkPage([6, 5, 4]))
        #expect(window.items.map(\.id) == ["item-4", "item-5", "item-6"])
        window.merge(sdkPage([4, 3, 2]), older: true)
        #expect(window.items.map(\.id) == ["item-2", "item-3", "item-4"])
        window.merge(sdkPage([4, 3, 2]), older: true)
        #expect(window.items.map(\.id) == ["item-2", "item-3", "item-4"])
        window.replace(with: sdkPage([8, 7, 6]))
        #expect(window.items.map(\.id) == ["item-6", "item-7", "item-8"])
        window.clear()
        #expect(window.items.isEmpty)
        #expect(window.byteCount == 0)
    }

    @Test func historyWindowBoundsUTF8BytesWhileVisitingLongHistory() {
        var window = PuckHistoryWindow(maxItems: 200, maxBytes: 2048)
        for page in 0..<100 {
            let items = (0..<50).map { item in
                PuckHistoryItem(id: "\(page)-\(item)", kind: "assistant", text: String(repeating: "鲸", count: 100))
            }
            window.merge(PuckHistoryPage(session: "fixture-session", source: "display", items: items, nextCursor: "next"), older: true)
            #expect(window.byteCount <= window.maxBytes)
            #expect(window.items.count <= window.maxItems)
            #expect(Set(window.items.map(\.id)).count == window.items.count)
        }
        let oversize = PuckHistoryItem(id: "large", kind: "assistant", text: String(repeating: "x", count: 10_000))
        window.replace(with: PuckHistoryPage(session: "fixture-session", source: "display", items: [oversize], nextCursor: nil))
        #expect(window.byteCount <= 2048)
    }

    @Test func notificationBufferOverloadRequiresReconnect() throws {
        let fixture = try SDKSocketFixture { peer, request in
            for cursor in 1...33 { try peer.notify(cursor: cursor, kind: "text_delta", text: "chunk") }
            try peer.reply(request, result: ["ok": true])
        }
        defer { fixture.stop() }
        let connection = try PuckDaemonConnection(socketPath: fixture.path)
        defer { connection.disconnect() }
        do {
            _ = try connection.request("session.attach", params: ["session": "fixture-session"])
            Issue.record("Unbounded notification buffering was accepted")
        } catch PuckDaemonError.unavailable(let detail) {
            #expect(detail.contains("overflow"))
            #expect(detail.contains("reconnect"))
        }
    }

    @Test func oversizedWireLineFailsAtByteLimit() throws {
        let fixture = try SDKSocketFixture { peer, _ in
            try peer.sendBytes(Data(repeating: 32, count: 4 * 1_048_576 + 1))
        }
        defer { fixture.stop() }
        let connection = try PuckDaemonConnection(socketPath: fixture.path)
        defer { connection.disconnect() }
        do {
            _ = try connection.request("session.attach", params: ["session": "fixture-session"])
            Issue.record("An oversized wire line was buffered")
        } catch PuckDaemonError.invalidResponse(let field) {
            #expect(field == "line too large")
        }
    }

    @Test func replayByteBudgetIncludesToolArguments() throws {
        let arguments = String(repeating: "x", count: 100_000)
        func event(_ cursor: Int) -> [String: Any] {
            ["cursor": cursor, "data": ["event": "tool_start", "tool": "fixture-tool", "arguments": arguments]]
        }
        let fixture = try SDKSocketFixture { peer, request in
            let after = (request["params"] as? [String: Any])?["after"] as? Int ?? 0
            let end = min(30, after + 5)
            try peer.reply(request, result: ["cursor": 30, "events": ((after + 1)...end).map(event)])
        }
        defer { fixture.stop() }
        let initial = try PuckEventBatch(["cursor": 30, "events": (1...5).map(event)])
        let replay = try PuckDaemonClient(socketPath: fixture.path).replay("fixture-session", initial: initial)
        let retainedBytes = replay.reduce(0) { $0 + ($1.arguments?.utf8.count ?? 0) + 256 }
        #expect(replay.last?.cursor == 30)
        #expect(retainedBytes <= 2 * 1_048_576)
    }

    @Test func initialReplayPageIsBoundedWithoutFetchingMore() throws {
        let arguments = String(repeating: "x", count: 100_000)
        let initial = try PuckEventBatch(["cursor": 30, "events": (1...30).map { cursor in
            ["cursor": cursor, "data": ["event": "tool_start", "arguments": arguments]] as [String: Any]
        }])
        let replay = try PuckDaemonClient(socketPath: "/tmp/puck-sdk-no-listener.sock").replay("fixture-session", initial: initial)
        #expect(replay.last?.cursor == 30)
        #expect(replay.count < 30)
        #expect(replay.reduce(0) { $0 + $1.retainedByteCount } <= 2 * 1_048_576)
    }

    @Test func slowFollowConsumerTerminatesInsteadOfGrowingQueue() async throws {
        let fixture = try SDKSocketFixture { peer, request in
            try peer.reply(request, result: sdkAttached(cursor: 1, events: [sdkEvent(1, text: "saved")]))
            for _ in 0..<20 { try peer.notify(cursor: 1, kind: "text_delta", text: "live", transient: true) }
        }
        defer { fixture.stop() }
        let stream = PuckClient(socketPath: fixture.path).follow("fixture-session")
        #expect(await sdkWait(fixture.detached))
        var buffered = 0
        do {
            for try await _ in stream { buffered += 1 }
            Issue.record("An overloaded follow stream ended without a reconnect error")
        } catch PuckDaemonError.unavailable(let detail) {
            #expect(detail.contains("lagged"))
            #expect(detail.contains("reconnect"))
        }
        #expect(buffered <= 8)
    }

    @Test func backgroundIORejectsExcessRequestsAndBoundsActiveOperations() async throws {
        let state = SDKBackgroundState()
        let release = DispatchSemaphore(value: 0)
        defer { for _ in 0..<80 { release.signal() } }
        let tasks = (0..<80).map { _ in
            Task { () -> Bool in
                do {
                    _ = try await PuckBackgroundIO.run {
                        state.begin()
                        defer { state.end() }
                        _ = release.wait(timeout: .now() + 10)
                        return 1
                    }
                    return true
                } catch PuckDaemonError.notSubmitted(let message) {
                    #expect(message.contains("queue is full"))
                    state.reject()
                    return false
                } catch {
                    Issue.record("Unexpected background I/O error: \(error)")
                    return false
                }
            }
        }
        try await sdkEventually { state.rejected == 16 && state.started == 4 }
        #expect(state.maximumActive == 4)
        #expect(state.started == 4)
        for _ in 0..<64 { release.signal() }
        var successful = 0
        for task in tasks { if await task.value { successful += 1 } }
        #expect(successful == 64)
        #expect(state.rejected == 16)
        #expect(state.maximumActive == 4)
        #expect(try await PuckBackgroundIO.run { 42 } == 42)
    }

    @Test func alreadyCancelledBackgroundRequestDoesNotExecute() async throws {
        let state = SDKBackgroundState()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PuckBackgroundIO.run { state.begin(); state.end(); return 1 }
        }
        do {
            _ = try await task.value
            Issue.record("An already cancelled request was accepted")
        } catch is CancellationError {}
        #expect(state.started == 0)
    }

    @Test func runningBackgroundCancellationDoesNotUndoDeliveredOperation() async throws {
        let state = SDKBackgroundState()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let task = Task {
            try await PuckBackgroundIO.run {
                state.begin()
                defer { state.end() }
                _ = release.wait(timeout: .now() + 10)
                return 1
            }
        }
        try await sdkEventually { state.started == 1 }
        task.cancel()
        release.signal()
        do { _ = try await task.value }
        catch is CancellationError {}
        try await sdkEventually { state.finished == 1 }
        #expect(state.started == 1)
        #expect(state.finished == 1)
    }

    @Test func cancelledQueuedBackgroundRequestDoesNotDeliverLatentWork() async throws {
        let state = SDKBackgroundState()
        let release = DispatchSemaphore(value: 0)
        defer { for _ in 0..<4 { release.signal() } }
        let blockers = (0..<4).map { _ in
            Task {
                try await PuckBackgroundIO.run {
                    state.begin()
                    defer { state.end() }
                    _ = release.wait(timeout: .now() + 10)
                    return 1
                }
            }
        }
        try await sdkEventually { state.started == 4 }
        let candidateReady = DispatchSemaphore(value: 0)
        let candidateResolved = DispatchSemaphore(value: 0)
        let candidate = Task {
            defer { candidateResolved.signal() }
            candidateReady.signal()
            return try await PuckBackgroundIO.run { state.begin(); state.end(); return 1 }
        }
        #expect(await sdkWait(candidateReady))
        // All workers are occupied, so the candidate remains queued. Give its
        // async entry time to reserve the operation before cancelling it.
        try await Task.sleep(for: .milliseconds(100))
        candidate.cancel()
        #expect(await sdkWait(candidateResolved))
        #expect(state.started == 4)
        for _ in 0..<4 { release.signal() }
        for blocker in blockers { _ = try await blocker.value }
        do {
            _ = try await candidate.value
            Issue.record("A cancelled queued request delivered latent work")
        } catch is CancellationError {}
        #expect(state.started == 4)
    }
}

private enum SDKFixtureError: Error { case socket(String), unexpectedMethod, invalidRequest }

private func sdkWait(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 3) == .success)
        }
    }
}

private func sdkEventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition() {
        guard ContinuousClock.now < deadline else { throw SDKFixtureError.socket("timed out waiting for background operations") }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private final class SDKBackgroundState: @unchecked Sendable {
    private let lock = NSLock()
    private var activeCount = 0
    private var startedCount = 0
    private var rejectedCount = 0
    private var finishedCount = 0
    private var maximumCount = 0
    var started: Int { lock.withLock { startedCount } }
    var rejected: Int { lock.withLock { rejectedCount } }
    var finished: Int { lock.withLock { finishedCount } }
    var maximumActive: Int { lock.withLock { maximumCount } }
    func begin() { lock.withLock { activeCount += 1; startedCount += 1; maximumCount = max(maximumCount, activeCount) } }
    func end() { lock.withLock { activeCount -= 1; finishedCount += 1 } }
    func reject() { lock.withLock { rejectedCount += 1 } }
}

private func sdkCapabilities(major: Int = 2) -> [String: Any] {
    ["protocol": ["major": major, "minor": 0], "engines": ["codex", "native"],
     "default_engine": "codex", "features": ["paged_history", "bounded_events"],
     "engine_capabilities": [["engine": "codex", "owns_coding_loop": true, "replaces_builtin_tools": false,
                              "exact_parked_recovery": false, "paged_history": "engine history", "adding_custom_tools": false]]]
}
private func sdkSummary() -> [String: Any] {
    ["id": "fixture-session", "engine": "codex", "provider": "fixture-provider",
     "account": "fixture-seat", "workspace": "/tmp/sdk-project", "cwd": "/tmp/sdk-project",
     "model": "fixture-model", "position": "running", "history_items": 0]
}
private func sdkEvent(_ cursor: Int, text: String) -> [String: Any] {
    ["cursor": cursor, "data": ["event": "assistant_message", "text": text]]
}
private func sdkAttached(cursor: Int, events: [[String: Any]] = []) -> [String: Any] {
    ["summary": sdkSummary(), "cursor": cursor, "events": events, "history_api": false]
}
private func sdkPage(_ ids: [Int]) -> PuckHistoryPage {
    PuckHistoryPage(session: "fixture-session", source: "display", items: ids.map {
        PuckHistoryItem(id: "item-\($0)", kind: "assistant", text: "message \($0)")
    }, nextCursor: "older")
}

private final class SDKSocketFixture: @unchecked Sendable {
    let path: String
    let detached = DispatchSemaphore(value: 0)
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var storedRequests: [[String: Any]] = []
    private var storedFailures: [String] = []
    private var peers: [SDKSocketPeer] = []
    private let handler: (SDKSocketPeer, [String: Any]) throws -> Void
    var requests: [[String: Any]] { lock.withLock { storedRequests } }
    var failures: [String] { lock.withLock { storedFailures } }

    init(handler: @escaping (SDKSocketPeer, [String: Any]) throws -> Void) throws {
        self.handler = handler
        path = "/tmp/puck-sdk-\(UUID().uuidString.prefix(12)).sock"
        #if canImport(Darwin)
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        listener = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard listener >= 0 else { throw SDKFixtureError.socket("socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0, listen(listener, 16) == 0 else {
            _ = close(listener); _ = unlink(path)
            throw SDKFixtureError.socket("bind/listen")
        }
        Thread { [self] in
            while !lock.withLock({ stopped }) {
                let descriptor = accept(listener, nil, nil)
                guard descriptor >= 0 else { break }
                let peer = SDKSocketPeer(descriptor)
                lock.withLock { peers.append(peer) }
                DispatchQueue.global().async { [self] in
                    defer { peer.closeSocket(); detached.signal() }
                    do {
                        while let request = try peer.readRequest() {
                            lock.withLock { storedRequests.append(request) }
                            try handler(peer, request)
                        }
                    } catch {
                        lock.withLock { storedFailures.append(String(describing: error)) }
                    }
                }
            }
        }.start()
    }

    func stop() {
        let active = lock.withLock { () -> [SDKSocketPeer] in
            guard !stopped else { return [] }
            stopped = true
            _ = shutdown(listener, Int32(SHUT_RDWR))
            _ = close(listener)
            return peers
        }
        active.forEach { $0.disconnect() }
        _ = unlink(path)
    }
    deinit { stop() }
}

private final class SDKSocketPeer: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var closed = false
    private var pending = Data()
    init(_ descriptor: Int32) {
        self.descriptor = descriptor
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var noSignal: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }
    func readRequest() throws -> [String: Any]? {
        while true {
            guard !lock.withLock({ closed }) else { return nil }
            if let newline = pending.firstIndex(of: 10) {
                let data = Data(pending[..<newline]); pending.removeSubrange(...newline)
                guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw SDKFixtureError.invalidRequest
                }
                return request
            }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = bytes.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { return nil }
            pending.append(contentsOf: bytes.prefix(count))
        }
    }
    func reply(_ request: [String: Any], result: Any) throws {
        try send(["jsonrpc": "2.0", "id": request["id"] ?? 1, "result": result])
    }
    func notify(cursor: Int, kind: String, text: String, transient: Bool = false) throws {
        try send(["jsonrpc": "2.0", "method": "session.event", "params": [
            "session": "fixture-session", "cursor": cursor,
            "data": ["event": kind, "text": text, "transient": transient]
        ]])
    }
    func send(_ value: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: value) + Data([10])
        try sendBytes(data)
    }
    func sendBytes(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                #if canImport(Darwin)
                let count = write(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                #else
                let count = Glibc.send(descriptor, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, Int32(MSG_NOSIGNAL))
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw SDKFixtureError.socket("write") }
                sent += count
            }
        }
    }
    func disconnect() { lock.withLock { if !closed { _ = shutdown(descriptor, Int32(SHUT_RDWR)) } } }
    func closeSocket() { lock.withLock { if !closed { closed = true; _ = close(descriptor) } } }
}
