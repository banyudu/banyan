import BanyanCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension BanyanCtl {
    func runPerfCommand(_ args: [String]) throws {
        let subcommand = args.first ?? "report"
        switch subcommand {
        case "energy":
            let options = try EnergyArguments(Array(args.dropFirst()))
            let report = try EnergyReportSampler.sample(seconds: options.seconds) {
                guard let executable = TmuxBackend.resolveExecutableURL(environment: host.environment) else {
                    throw TmuxBackend.BackendError.tmuxNotFound
                }
                return try TmuxBackend(executableURL: executable, workingDirectory: host.currentDirectory,
                    environment: host.environment,
                    socketName: TmuxBackend.resolvedSocketName(environment: host.environment)).energySessionRoots()
            }
            if options.json {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(report), as: UTF8.self))
            } else {
                print(report.formatted())
            }
        case "captures":
            let options = try parsePerfReportOptions(Array(args.dropFirst()))
            let store = ResourceSpikeCaptureStore(directoryURL: ResourceSpikeCaptureStore.defaultDirectoryURL(host: host))
            let records = store.records(since: options.since)
            if options.json {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                print(String(decoding: try encoder.encode(records), as: UTF8.self))
            } else if records.isEmpty {
                print("No Banyan CPU spike captures in the requested window. Directory: \(store.directoryURL.path)")
            } else {
                for record in records {
                    print("\(record.createdAt.formatted(.iso8601)) cpu=\(String(format: "%.1f", record.trigger.cpuPercent))% activity=\(record.trigger.context.activity) status=\(record.status)")
                    print("  \(store.captureDirectory(id: record.id).path)")
                    if let error = record.error { print("  \(error)") }
                }
            }
        case "report":
            let options = try parsePerfReportOptions(Array(args.dropFirst()))
            let store = PerformanceEventStore(databaseURL: PerformanceEventStore.defaultDatabaseURL(host: host))
            if options.json {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(store.report(since: options.since))
                print(String(data: data, encoding: .utf8) ?? "{}")
            } else {
                print(store.formattedReport(since: options.since))
            }
        case "prompt":
            let options = try parsePerfFixOptions(Array(args.dropFirst()))
            print(makePerformanceFixPrompt(since: options.since))
        case "fix":
            let options = try parsePerfFixOptions(Array(args.dropFirst()))
            let store = PerformanceEventStore(databaseURL: PerformanceEventStore.defaultDatabaseURL(host: host))
            let report = store.report(since: options.since)
            guard report.eventCount > 0 else {
                throw CLIError.message("no performance events found for the requested window")
            }
            try post("/spawn", payload: withDefaultParent([
                "title": "Fix Banyan performance",
                "cwd": options.cwd,
                "command": AgentLaunchCommand.command(
                    provider: options.provider,
                    prompt: makePerformanceFixPrompt(since: options.since)
                )
            ]))
        default:
            throw CLIError.message("unknown perf subcommand '\(subcommand)'")
        }
    }

    private func parsePerfReportOptions(_ args: [String]) throws -> (since: Date, json: Bool) {
        var since = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        var json = false
        var index = 0
        while index < args.count {
            let token = args[index]
            switch token {
            case "--json":
                json = true
                index += 1
            case "--since":
                guard index + 1 < args.count else {
                    throw CLIError.message("missing value for --since")
                }
                since = try parseSince(args[index + 1])
                index += 2
            default:
                throw CLIError.message("unknown perf report option '\(token)'")
            }
        }
        return (since, json)
    }

    private func parsePerfFixOptions(_ args: [String]) throws -> (since: Date, provider: CodingAgentProvider, cwd: String) {
        var since = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        var provider = CodingAgentProvider.codex
        var cwd = host.currentDirectory
        var index = 0
        while index < args.count {
            let token = args[index]
            switch token {
            case "--since":
                guard index + 1 < args.count else {
                    throw CLIError.message("missing value for --since")
                }
                since = try parseSince(args[index + 1])
                index += 2
            case "--agent", "--provider":
                guard index + 1 < args.count else {
                    throw CLIError.message("missing value for \(token)")
                }
                guard let parsedProvider = CodingAgentProvider(agentName: args[index + 1]) else {
                    throw CLIError.message("unknown agent '\(args[index + 1])'")
                }
                provider = parsedProvider
                index += 2
            case "--cwd":
                guard index + 1 < args.count else {
                    throw CLIError.message("missing value for --cwd")
                }
                cwd = NSString(string: args[index + 1]).expandingTildeInPath
                index += 2
            default:
                throw CLIError.message("unknown perf option '\(token)'")
            }
        }
        return (since, provider, cwd)
    }

    private func makePerformanceFixPrompt(since: Date) -> String {
        let report = PerformanceEventStore(
            databaseURL: PerformanceEventStore.defaultDatabaseURL(host: host)
        ).formattedReport(since: since)
        return """
        We need to fix Banyan performance regressions using collected local telemetry.

        Use the report below as evidence. Prioritize the highest p95 or slow-count metric, inspect the related code path, implement a targeted fix, and run the relevant tests. Keep the patch scoped to Banyan performance; do not refactor unrelated behavior.

        For battery or Energy Impact complaints, first run `banyanctl perf energy --seconds 10` and inspect the owning session and child processes. CPU spike captures cover only the app PID. Activity Monitor's 12 hr Power is historical; do not infer a current app loop from it or treat a subprocess workload as a rendering regression. Do not stop user jobs without authorization.

        Performance report:
        \(report)
        """
    }

    private func parseSince(_ value: String) throws -> Date {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let interval = Self.relativeInterval(from: trimmed) {
            return Date().addingTimeInterval(-interval)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) {
            return date
        }
        throw CLIError.message("--since must be a relative duration like 7d, 12h, 30m or an ISO-8601 date")
    }

    private static func relativeInterval(from value: String) -> TimeInterval? {
        guard let unit = value.last else { return nil }
        let numberText = String(value.dropLast())
        guard let amount = Double(numberText), amount >= 0 else { return nil }
        switch unit {
        case "m": return amount * 60
        case "h": return amount * 60 * 60
        case "d": return amount * 24 * 60 * 60
        case "w": return amount * 7 * 24 * 60 * 60
        default: return nil
        }
    }
}
