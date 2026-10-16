import Foundation
import Testing
@testable import BanyanCore

private func titleRPC(_ method: String, params: [String: Any] = [:], update: (String) throws -> Bool = { _ in true }) throws -> [String: Any] {
    let data = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": "request-1", "method": method, "params": params])
    let rawResponse = SessionTitleMCP.response(to: data, updateTitle: update)
    let response = try #require(rawResponse)
    let decoded = try #require(JSONSerialization.jsonObject(with: response) as? [String: Any])
    #expect(decoded["id"] as? String == "request-1")
    return decoded
}

@Test func sessionTitleMCPAdvertisesOneScopedToolAndContextInstructions() throws {
    let initialize = try titleRPC("initialize", params: ["protocolVersion": "2025-06-18"])
    let result = try #require(initialize["result"] as? [String: Any])
    #expect(result["protocolVersion"] as? String == "2025-06-18")
    #expect((result["instructions"] as? String)?.contains("significant finding") == true)
    let listed = try titleRPC("tools/list")
    let tools = try #require((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(tools.count == 1)
    let schema = try #require(tools.first?["inputSchema"] as? [String: Any])
    #expect(Set((schema["properties"] as? [String: Any] ?? [:]).keys) == ["title"])
    #expect(schema["additionalProperties"] as? Bool == false)
}

@Test func sessionTitleMCPUpdatesFromFindingsAndPreservesManualTitles() throws {
    var titles: [String] = []
    let response = try titleRPC("tools/call", params: ["name": "rename_session", "arguments": ["title": "  Checkout timeout:\nexhausted DB pool  "]]) { title in
        titles.append(title)
        return true
    }
    #expect(titles == ["Checkout timeout: exhausted DB pool"])
    #expect((response["result"] as? [String: Any])?["isError"] as? Bool == false)
    let pinned = try titleRPC("tools/call", params: ["name": "rename_session", "arguments": ["title": "New finding"]]) { _ in false }
    let content = (pinned["result"] as? [String: Any])?["content"] as? [[String: String]]
    #expect(content?.first?["text"]?.contains("Manual session title preserved") == true)
}

@Test func sessionTitleMCPRejectsInvalidOrCrossSessionArguments() throws {
    for arguments: [String: Any] in [["title": "shell"], ["title": "   "], ["title": 42],
                                    ["title": "Finding", "id": "other-session"], ["title": String(repeating: "x", count: 201)]] {
        let response = try titleRPC("tools/call", params: ["name": "rename_session", "arguments": arguments]) { _ in
            Issue.record("Invalid arguments must not reach the app")
            return true
        }
        #expect((response["error"] as? [String: Any])?["code"] as? Int == -32602)
    }
    let failure = try titleRPC("tools/call", params: ["name": "rename_session", "arguments": ["title": "Finding"]]) { _ in
        throw NSError(domain: "fixture", code: 1)
    }
    #expect((failure["result"] as? [String: Any])?["isError"] as? Bool == true)
    let notification = Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8)
    #expect(SessionTitleMCP.response(to: notification) { _ in true } == nil)
    let malformed = try #require(SessionTitleMCP.response(to: Data("bad JSON".utf8)) { _ in true })
    #expect((try JSONSerialization.jsonObject(with: malformed) as? [String: Any])?["error"] != nil)
}

@Test func sessionTitleRouteRequiresASessionAndSpecificTitle() throws {
    #expect(ControlRoute.resolve(method: "POST", path: "/session-title") == .sessionTitle)
    #expect(throws: ControlValidationError.missingID) { try ControlRoute.sessionTitle.validate(.init(title: "Finding")) }
    #expect(throws: ControlValidationError.missingTitle) { try ControlRoute.sessionTitle.validate(.init(id: "session", title: " ")) }
    try ControlRoute.sessionTitle.validate(.init(id: "session", title: "Checkout DB pool exhausted"))
}
