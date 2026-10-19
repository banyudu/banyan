import Foundation
import Testing
@testable import BanyanCore

@Test func sessionListDefaultsKeepOpenStatusesAndSkipHistoryBeforeReadingDetails() throws {
    let options = try SessionListOptions()
    for status in SessionStatus.allCases {
        var detailReads = 0
        let matches = options.matches(id: "session", status: status.rawValue) {
            detailReads += 1
            return ["Title"]
        }
        #expect(matches == (status != .closed))
        #expect(detailReads == 0)
    }
}

@Test func sessionListExactIDFindsClosedHistoryAndDoesNotMatchPrefixes() throws {
    let options = try SessionListOptions(arguments: ["--id", "TASK-12"])
    #expect(options.matches(id: "TASK-12", status: "closed") { [] })
    #expect(!options.matches(id: "TASK-123", status: "running") { [] })
    #expect(!options.matches(id: "task-12", status: "running") { [] })
}

@Test func sessionListSearchIsCaseInsensitiveAndHistoryIsExplicit() throws {
    let active = try SessionListOptions(arguments: ["--query", " WIDGET "])
    #expect(active.matches(id: "widget-session", status: "running") { [] })
    #expect(active.matches(id: "other", status: "completed") { ["Fix the Widget", "/tmp/project"] })
    #expect(active.matches(id: "other", status: "failed") { ["Title", "/tmp/widget"] })
    #expect(!active.matches(id: "other", status: "running") { ["Unrelated"] })
    var readClosedDetails = false
    #expect(!active.matches(id: "history", status: "closed") {
        readClosedDetails = true
        return ["Widget"]
    })
    #expect(!readClosedDetails)
    let all = try SessionListOptions(arguments: ["--all", "--query", "widget"])
    #expect(all.matches(id: "history", status: "closed") { ["Widget"] })
}

@Test func sessionListOptionsRoundTripThroughEncodedHTTPQuery() throws {
    let options = try SessionListOptions(arguments: ["--all", "--id", "session & one", "--query", "some/path ?"])
    var components = URLComponents()
    components.path = "/list"
    components.queryItems = options.queryItems.map { URLQueryItem(name: $0.key, value: $0.value) }
    let path = try #require(components.string)
    #expect(ControlRoute.resolve(method: "GET", path: path) == .list)
    #expect(try SessionListOptions(queryItems: ControlRoute.queryItems(in: path)) == options)
}

@Test func sessionListRejectsAmbiguousOrInvalidOptions() {
    for args in [["--id"], ["--query", "--all"], ["--all", "--all"], ["--unknown"], ["--query", " "], ["--id", ""]] {
        #expect(throws: ControlValidationError.self) { try SessionListOptions(arguments: args) }
    }
    for items in [["all": "yes"], ["query": " "], ["id": ""], ["unexpected": "true"]] {
        #expect(throws: ControlValidationError.self) { try SessionListOptions(queryItems: items) }
    }
}
