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

@Test func tickRouteCanTargetOneSessionOrAllSessions() throws {
    #expect(ControlRoute.resolve(method: "POST", path: "/tick") == .tick)

    try ControlRoute.tick.validate(ControlPayload(apiVersion: "v1", id: nil))
    try ControlRoute.tick.validate(ControlPayload(apiVersion: "v1", id: "agent"))
}

@Test func restartRouteRequiresSessionID() throws {
    #expect(ControlRoute.resolve(method: "POST", path: "/restart") == .restart)

    #expect(throws: ControlValidationError.missingID) {
        try ControlRoute.restart.validate(ControlPayload(apiVersion: "v1", id: nil))
    }

    try ControlRoute.restart.validate(ControlPayload(apiVersion: "v1", id: "agent"))
}

@Test func recoverRouteCanTargetOneSessionOrEveryStrandedSession() throws {
    #expect(ControlRoute.resolve(method: "POST", path: "/recover") == .recover)
    #expect(ControlRoute.resolve(method: "GET", path: "/recover") == nil)

    // No id is the scriptable "Recover All", so it must not be a 400.
    try ControlRoute.recover.validate(ControlPayload(apiVersion: "v1", id: nil))
    try ControlRoute.recover.validate(ControlPayload(apiVersion: "v1", id: "agent"))
}

@Test func selectRouteRequiresSessionID() throws {
    #expect(ControlRoute.resolve(method: "POST", path: "/select") == .select)

    #expect(throws: ControlValidationError.missingID) {
        try ControlRoute.select.validate(ControlPayload(apiVersion: "v1", id: nil))
    }

    try ControlRoute.select.validate(ControlPayload(apiVersion: "v1", id: "agent"))
}

@Test func suspendAndResumeRoutesRequireSessionID() throws {
    #expect(ControlRoute.resolve(method: "POST", path: "/suspend") == .suspend)
    #expect(ControlRoute.resolve(method: "POST", path: "/resume") == .resume)
    #expect(ControlRoute.resolve(method: "GET", path: "/suspend") == nil)

    for route in [ControlRoute.suspend, .resume] {
        #expect(throws: ControlValidationError.missingID) {
            try route.validate(ControlPayload(apiVersion: "v1", id: nil))
        }
        try route.validate(ControlPayload(apiVersion: "v1", id: "agent"))
    }
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

@Test func paneRoutesResolveAndRequireASession() throws {
    #expect(ControlRoute.resolve(method: "GET", path: "/output") == .output)
    #expect(ControlRoute.resolve(method: "POST", path: "/input") == .input)
    #expect(ControlRoute.resolve(method: "POST", path: "/answer") == .answer)
    #expect(ControlRoute.resolve(method: "GET", path: "/events") == .events)

    // Reading or typing into "some session" is not a request anyone can serve.
    for route in [ControlRoute.output, .input, .answer] {
        #expect(throws: ControlValidationError.missingID) {
            try route.validate(ControlPayload(apiVersion: "v1", id: nil))
        }
    }
    try ControlRoute.events.validate(ControlPayload(apiVersion: "v1", id: nil))
}

@Test func paneRoutesResolveWithAQueryString() {
    // `/output` and `/events` are documented as GETs with parameters, so route
    // matching has to survive them.
    #expect(ControlRoute.resolve(method: "GET", path: "/output?id=agent&lines=40") == .output)
    #expect(ControlRoute.resolve(method: "GET", path: "/events?since=12") == .events)

    let query = ControlRoute.queryItems(in: "/output?id=agent%20one&lines=40")
    #expect(query["id"] == "agent one")
    #expect(query["lines"] == "40")
    #expect(ControlRoute.queryItems(in: "/list").isEmpty)
}

@Test func inputRouteRequiresSomethingToSend() throws {
    #expect(throws: ControlValidationError.missingInput) {
        try ControlRoute.input.validate(ControlPayload(apiVersion: "v1", id: "agent"))
    }

    try ControlRoute.input.validate(ControlPayload(apiVersion: "v1", id: "agent", keys: ["Enter"]))
    try ControlRoute.input.validate(ControlPayload(apiVersion: "v1", id: "agent", text: "hello"))
    try ControlRoute.input.validate(ControlPayload(apiVersion: "v1", id: "agent", submit: true))
}

@Test func answerRouteRequiresAFootprint() throws {
    // Without it there is no way to tell the prompt a human read from the one on
    // screen now, which is the whole guard.
    #expect(throws: ControlValidationError.missingFootprint) {
        try ControlRoute.answer.validate(ControlPayload(apiVersion: "v1", id: "agent", option: 1))
    }

    try ControlRoute.answer.validate(
        ControlPayload(apiVersion: "v1", id: "agent", option: 1, footprint: "abc")
    )
}

@Test func answerPayloadDecodesFromNativeJSONOrItsStringSpelling() throws {
    // `banyanctl` posts a flat string dictionary; a bridge written against the
    // documented JSON shape posts real numbers and booleans. Both are the same
    // request and both have to decode.
    let native = #"{"apiVersion":"v1","id":"agent","option":2,"confirm":false,"footprint":"abc","lines":40}"#
    let strings = #"{"apiVersion":"v1","id":"agent","option":"2","confirm":"false","footprint":"abc","lines":"40"}"#

    for body in [native, strings] {
        let raw = "POST /answer HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let request = try #require(HTTPControlRequest(data: Data(raw.utf8)))
        let payload = try request.decode(ControlPayload.self)

        #expect(payload.option?.value == 2)
        #expect(payload.confirm?.value == false)
        #expect(payload.lines?.value == 40)
        #expect(payload.footprint == "abc")
    }
}

@Test func inputPayloadKeepsKeysInTheOrderTheyWereSent() throws {
    let body = #"{"apiVersion":"v1","id":"agent","keys":["Down","Down","Enter"],"text":"Enter"}"#
    let raw = "POST /input HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    let request = try #require(HTTPControlRequest(data: Data(raw.utf8)))

    let payload = try request.decode(ControlPayload.self)

    #expect(payload.keys == ["Down", "Down", "Enter"])
    // `text` stays text: it is typed verbatim, never resolved as a key name.
    #expect(payload.text == "Enter")
}

@Test func nonNumericPayloadValuesAreRejectedRatherThanSilentlyZeroed() throws {
    let body = #"{"apiVersion":"v1","id":"agent","option":"second"}"#
    let raw = "POST /answer HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
    let request = try #require(HTTPControlRequest(data: Data(raw.utf8)))

    #expect(throws: DecodingError.self) {
        _ = try request.decode(ControlPayload.self)
    }
}
