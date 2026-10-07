import Foundation
import Testing
@testable import BanyanCore

private func fields(_ thread: String = "thread-a", _ turn: String = "turn-1", _ extra: [String: CodexJSONValue]) -> CodexJSONValue {
    .object(extra.merging(["threadId": .string(thread), "turnId": .string(turn)]) { _, new in new })
}

private func fields(_ extra: [String: CodexJSONValue]) -> CodexJSONValue {
    fields("thread-a", "turn-1", extra)
}

@Test func codexConversationRoutesRepeatedItemIDsAcrossThreadsAndTurns() throws {
    var first = CodexConversation()
    var second = CodexConversation()
    let a = fields("thread-a", "turn-1", ["itemId": .string("message"), "delta": .string("First")])
    let b = fields("thread-b", "turn-1", ["itemId": .string("message"), "delta": .string("Second")])
    for event in [a, b] {
        first.receive(method: "item/agentMessage/delta", params: event, threadID: "thread-a")
        second.receive(method: "item/agentMessage/delta", params: event, threadID: "thread-b")
    }
    first.receive(method: "item/agentMessage/delta", params: fields("thread-a", "turn-2", [
        "itemId": .string("message"), "delta": .string("New turn")]), threadID: "thread-a")
    first.receive(method: "item/agentMessage/delta", params: fields(["itemId": .string("message"), "delta": .string(" late")]), threadID: "thread-a")
    #expect(first.turns.map { $0.items.first?.text } == ["First late", "New turn"])
    #expect(second.turns.map { $0.items.first?.text } == ["Second"])
}

@Test func codexConversationCompletedItemsOverrideDeltasAndKeepStructuredOutput() throws {
    var model = CodexConversation()
    model.receive(method: "item/commandExecution/outputDelta", params: fields([
        "itemId": .string("cmd"), "delta": .string("\u{1b}[31mHello\u{1b}[0m\n")]), threadID: "thread-a")
    #expect(model.turns[0].items[0].readableOutput == "Hello\n")
    let item: CodexJSONValue = .object(["id": .string("cmd"), "type": .string("commandExecution"),
        "command": .string("swift test"), "status": .string("completed"),
        "aggregatedOutput": .string("All tests passed\n"), "exitCode": .integer(0)])
    model.receive(method: "item/completed", params: fields(["item": item]), threadID: "thread-a")
    model.receive(method: "item/commandExecution/outputDelta", params: fields([
        "itemId": .string("cmd"), "delta": .string("incorrect late output")]), threadID: "thread-a")
    #expect(model.turns[0].items[0].text == "swift test")
    #expect(model.turns[0].items[0].readableOutput == "All tests passed\n")
    let file: CodexJSONValue = .object(["id": .string("file"), "type": .string("fileChange"),
        "changes": .array([.object(["path": .string("Sources/Example.swift"), "kind": .object(["type": .string("update")]), "diff": .string("-old\n+new")])])])
    model.receive(method: "item/completed", params: fields(["item": file]), threadID: "thread-a")
    #expect(model.turns[0].items[1].value == file)
    model.receive(method: "turn/diff/updated", params: fields(["diff": .string("diff --git a/example b/example\n-old\n+new")]), threadID: "thread-a")
    #expect(model.turns[0].diff.contains("+new"))
}

@Test func codexConversationHydrationKeepsEventsThatArriveDuringResume() throws {
    var model = CodexConversation()
    model.beginHydration()
    model.receive(method: "item/agentMessage/delta", params: fields(["itemId": .string("reply"), "delta": .string("Newest text")]), threadID: "thread-a")
    let snapshot: CodexJSONValue = .object(["id": .string("thread-a"), "turns": .array([
        .object(["id": .string("history"), "status": .string("completed"), "items": .array([
            .object(["id": .string("old"), "type": .string("agentMessage"), "text": .string("History")])])]),
        .object(["id": .string("turn-1"), "status": .string("inProgress"), "items": .array([
            .object(["id": .string("reply"), "type": .string("agentMessage"), "text": .string("Stale text")])])])
    ])])
    model.hydrate(thread: snapshot, threadID: "thread-a")
    #expect(model.turns.map(\.id) == ["history", "turn-1"])
    #expect(model.turns[1].items[0].text == "Newest text")
    // A later explicit reconnect may replace stale local content with history.
    model.beginHydration()
    model.hydrate(thread: snapshot, threadID: "thread-a")
    #expect(model.turns[1].items[0].text == "Stale text")
    model.hydrate(thread: .object(["id": .string("wrong-thread"), "turns": .array([])]), threadID: "thread-a")
    #expect(model.turns.count == 2)
}

@Test func codexConversationPreservesUnknownItemsAndBoundedEventDetails() {
    var model = CodexConversation()
    let unknown: CodexJSONValue = .object(["id": .string("future"), "type": .string("futureTool"), "newField": .array([.integer(42)])])
    model.receive(method: "item/started", params: fields(["item": unknown]), threadID: "thread-a")
    for index in 0..<205 {
        model.receive(method: "future/event", params: fields(["sequence": .integer(Int64(index))]), threadID: "thread-a")
    }
    #expect(model.turns[0].items[0].value == unknown)
    #expect(model.diagnostics.count == 200)
    #expect(model.diagnostics.last?.params.objectValue?["sequence"] == .integer(204))
    #expect(model.diagnostics.last?.params.inspectableText.contains("204") == true)
}

@Test func codexConversationApprovalRepliesRespectOfferedDecisions() throws {
    let command = CodexConversationRequest(.init(id: .integer(7), method: "item/commandExecution/requestApproval",
        params: fields(["availableDecisions": .array([.string("decline"), .string("cancel"), .object(["futureGrant": .bool(true)])])])))
    #expect(command.decisions == [.decline, .cancel])
    #expect(throws: CodexAppServerError.self) { try command.approvalReply(.accept) }
    for decision in command.decisions {
        if case .result(let reply) = try command.approvalReply(decision) { #expect(reply == .object(["decision": .string(decision.rawValue)])) }
        else { Issue.record("Expected decision payload") }
    }
    let file = CodexConversationRequest(.init(id: .string("file"), method: "item/fileChange/requestApproval", params: fields([:])))
    #expect(file.decisions == [.accept, .decline, .cancel])
    let unknown = CodexConversationRequest(.init(id: .integer(1), method: "future/request", params: fields([:])))
    #expect(unknown.decisions.isEmpty)
    #expect(throws: CodexAppServerError.self) { try unknown.approvalReply(.accept) }
}

@Test func codexConversationInputRepliesUseQuestionIDsAndNoInventedDeclineAnswer() throws {
    let request = CodexConversationRequest(.init(id: .string("question"), method: "item/tool/requestUserInput", params: fields([
        "questions": .array([.object(["id": .string("choice"), "question": .string("Choose"), "options": .array([
            .object(["label": .string("Yes")]), .object(["label": .string("No")])])]),
            .object(["id": .string("text"), "question": .string("Details"), "isSecret": .bool(true)])])
    ])))
    #expect(request.questions[1].isSecret)
    #expect(throws: CodexAppServerError.self) { try request.inputReply(["choice": "Yes"]) }
    #expect(throws: CodexAppServerError.self) { try request.inputReply(["choice": "made-up", "text": "details"]) }
    if case .result(let reply) = try request.inputReply(["choice": "No", "text": "details"]) {
        #expect(reply.objectValue?["answers"]?.objectValue?["choice"] == .object(["answers": .array([.string("No")])]))
    } else { Issue.record("Expected input payload") }
    if case .result(let skipped) = request.skippedInputReply { #expect(skipped == .object(["answers": .object([:])])) }
}

@Test func codexConversationOutputStripsCSIAndOSCWithoutExecutingEscapes() {
    #expect(CodexConversationText.plain("\u{1b}]8;;https://example.com\u{7}Link\u{1b}]8;;\u{7}\u{1b}[32m OK\u{1b}[0m\r\n") == "Link OK\n")
}

@Test func codexConversationBoundsLongStreamsRowsAndUnknownPayloads() {
    var model = CodexConversation()
    let chunk = String(repeating: "x", count: 4096)
    for _ in 0..<2048 {
        model.receive(method: "item/commandExecution/outputDelta", params: fields([
            "itemId": .string("long-command"), "delta": .string(chunk)]), threadID: "thread-a")
    }
    #expect(model.turns[0].items[0].output.utf8.count == CodexConversationBudget.outputBytes)
    #expect(model.turns[0].items[0].omittedOutputBytes == 2048 * 4096 - CodexConversationBudget.outputBytes)
    let huge: CodexJSONValue = .array(Array(repeating: .string(chunk), count: 1000))
    model.receive(method: "item/started", params: fields(["item": .object([
        "id": .string("unknown"), "type": .string("futureItem"), "payload": huge])]), threadID: "thread-a")
    #expect(model.turns[0].items[1].omittedPayloadBytes > 0)
    #expect(model.turns[0].items[1].value.inspectableText.utf8.count < CodexConversationBudget.payloadBytes + 1024)
    for turn in 0..<100 {
        for item in 0..<10 {
            model.receive(method: "item/agentMessage/delta", params: fields("thread-a", "turn-\(turn)", [
                "itemId": .string("item-\(item)"), "delta": .string("message")]), threadID: "thread-a")
        }
    }
    #expect(model.turns.count <= CodexConversationBudget.turns)
    #expect(model.turns.reduce(0) { $0 + $1.items.count } <= CodexConversationBudget.items)
    #expect(model.omittedTurns > 0)
    #expect(model.omittedItems > 0)
    for index in 0..<100 {
        model.receive(method: "item/started", params: fields("thread-a", "malformed-\(index)", [:]), threadID: "thread-a")
    }
    #expect(model.turns.count <= CodexConversationBudget.turns)
    model.receive(method: "future/event", params: fields(["payload": huge]), threadID: "thread-a")
    #expect(model.diagnostics.last?.omittedBytes ?? 0 > 0)
    #expect(model.diagnostics.last?.params.inspectableText.utf8.count ?? 0 < CodexConversationBudget.diagnosticBytes + 1024)
    model.releaseHistory()
    #expect(model.turns.isEmpty && model.diagnostics.isEmpty)
    #expect(model.omittedItems == 0 && model.omittedTurns == 0)
}

@Test func codexConversationToolTextIsReadableAndGlobalEventsAreInspectable() {
    var model = CodexConversation()
    model.receive(method: "item/completed", params: fields(["item": .object([
        "id": .string("mcp"), "type": .string("mcpToolCall"), "result": .object([
            "content": .array([.object(["type": .string("text"), "text": .string("line one\nline two")])])])])]), threadID: "thread-a")
    #expect(model.turns[0].items[0].toolOutput == "line one\nline two")
    model.receive(method: "future/global", params: .object(["details": .string("new field")]), threadID: "thread-a")
    #expect(model.diagnostics.last?.method == "future/global")
}
