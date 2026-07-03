import Foundation
import Testing
@testable import BanyanCore

@Test func completeRequestRequiresFullBody() throws {
    let body = #"{"apiVersion":"v1","id":"abc"}"#
    let header = "POST /mark HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
    let partial = Data((header + #"{"apiVersion":"v1""#).utf8)
    #expect(ControlProtocol.isCompleteHTTPMessage(partial) == false)

    let complete = Data((header + body).utf8)
    #expect(ControlProtocol.isCompleteHTTPMessage(complete) == true)
}

@Test func requestParserExtractsMethodPathAndJSONBody() throws {
    let body = #"{"apiVersion":"v1","id":"abc","status":"need-input"}"#
    let raw = "POST /mark HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    let request = try #require(HTTPControlRequest(data: Data(raw.utf8)))

    #expect(request.method == "POST")
    #expect(request.path == "/mark")
    #expect(request.headers["content-length"] == "\(body.utf8.count)")

    let payload = try request.decode(ControlPayload.self)
    #expect(payload.apiVersion == "v1")
    #expect(payload.id == "abc")
    #expect(payload.status == "need-input")
}

@Test func requestParserExtractsParentSessionID() throws {
    let body = #"{"apiVersion":"v1","id":"child","parent":"parent","command":"codex"}"#
    let raw = "POST /spawn HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    let request = try #require(HTTPControlRequest(data: Data(raw.utf8)))

    let payload = try request.decode(ControlPayload.self)
    #expect(payload.id == "child")
    #expect(payload.parent == "parent")
    #expect(payload.command == "codex")
}

@Test func malformedJSONThrowsDuringDecode() throws {
    let body = #"{"apiVersion":"v1","id":"abc""#
    let raw = "POST /mark HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    let request = try #require(HTTPControlRequest(data: Data(raw.utf8)))

    #expect(throws: DecodingError.self) {
        _ = try request.decode(ControlPayload.self)
    }
}

@Test func unknownRouteIsRejected() {
    #expect(ControlRoute.resolve(method: "POST", path: "/unknown") == nil)
}

@Test func windowStateRouteIsReadOnly() {
    #expect(ControlRoute.resolve(method: "GET", path: "/window-state") == .windowState)
    #expect(ControlRoute.resolve(method: "POST", path: "/window-state") == nil)
}

@Test func missingRequiredIDIsRejected() throws {
    let payload = ControlPayload(apiVersion: "v1", id: nil)

    #expect(throws: ControlValidationError.missingID) {
        try ControlRoute.close.validate(payload)
    }
}

@Test func screenshotRouteRequiresPath() throws {
    #expect(ControlRoute.resolve(method: "POST", path: "/screenshot") == .screenshot)

    #expect(throws: ControlValidationError.missingPath) {
        try ControlRoute.screenshot.validate(ControlPayload(apiVersion: "v1", path: nil))
    }

    try ControlRoute.screenshot.validate(ControlPayload(apiVersion: "v1", path: "/tmp/banyan.png"))
}
