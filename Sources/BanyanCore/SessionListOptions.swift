import Foundation

/// Filters inventory before detailed rows are constructed. Exact lookups can
/// read closed history without downloading the rest of the catalog.
public struct SessionListOptions: Equatable, Sendable {
    public let includeClosed: Bool
    public let id: String?
    public let query: String?

    public init(queryItems: [String: String] = [:]) throws {
        for key in queryItems.keys where !["all", "id", "query"].contains(key) {
            throw ControlValidationError.invalidSessionListOption("Unknown session list option '\(key)'")
        }
        if let all = queryItems["all"], !["true", "false"].contains(all) {
            throw ControlValidationError.invalidSessionListOption("Session list all must be true or false")
        }
        for key in ["id", "query"] {
            if let value = queryItems[key], value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ControlValidationError.invalidSessionListOption("Session list \(key) must not be empty")
            }
        }
        includeClosed = queryItems["all"] == "true"
        id = queryItems["id"]
        query = queryItems["query"]?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public init(arguments: [String]) throws {
        var items: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            let key: String
            switch flag {
            case "--all": key = "all"
            case "--id": key = "id"
            case "--query": key = "query"
            default: throw ControlValidationError.invalidSessionListOption("Unknown session list option '\(flag)'")
            }
            guard items[key] == nil else { throw ControlValidationError.invalidSessionListOption("Duplicate session list option '\(flag)'") }
            if key == "all" {
                items[key] = "true"
            } else {
                index += 1
                guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                    throw ControlValidationError.invalidSessionListOption("\(flag) requires a value")
                }
                items[key] = arguments[index]
            }
            index += 1
        }
        try self.init(queryItems: items)
    }

    public var queryItems: [String: String] {
        var items: [String: String] = [:]
        if includeClosed { items["all"] = "true" }
        if let id { items["id"] = id }
        if let query { items["query"] = query }
        return items
    }

    public func matches(id: String, status: String, searchValues: () -> [String]) -> Bool {
        if let wanted = self.id {
            guard id == wanted else { return false }
        } else if !includeClosed && status == "closed" {
            return false
        }
        guard let query else { return true }
        return ([id] + searchValues()).contains { $0.localizedCaseInsensitiveContains(query) }
    }
}
