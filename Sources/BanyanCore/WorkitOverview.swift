import Foundation

public struct WorkitOverview: Decodable, Sendable, Equatable {
    public let version: Int
    public let generatedAt: String
    public let total: Int
    public let truncated: Bool
    public let jobs: [WorkitJobSummary]

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4 * 1024 * 1024 else { throw WorkitOverviewError.invalidResponse }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.version == 1, value.jobs.count <= 1000, value.total >= value.jobs.count,
              Set(value.jobs.map(\.id)).count == value.jobs.count,
              value.jobs.allSatisfy({ !$0.id.isEmpty && $0.title.count <= 600 && $0.detail.count <= 1000
                  && $0.nextAction.count <= 1000 && $0.progress.passed >= 0 && $0.progress.total >= $0.progress.passed
                  && $0.evidence.count <= 5 }) else { throw WorkitOverviewError.invalidResponse }
        return value
    }
}

public struct WorkitJobSummary: Decodable, Sendable, Equatable, Identifiable {
    public enum Group: String, Decodable, Sendable, CaseIterable {
        case needsYou = "needs-you", working, waiting, paused, verified, cancelled
        public var label: String {
            switch self {
            case .needsYou: "Needs a decision"
            case .working: "Working"
            case .waiting: "Waiting"
            case .paused: "Paused"
            case .verified: "Verified"
            case .cancelled: "Cancelled"
            }
        }
    }
    public struct Progress: Decodable, Sendable, Equatable { public let passed: Int; public let total: Int }
    public let id: String
    public let revision: Int
    public let title: String
    public let issueURL: String?
    public let sessionID: String?
    public let stage: String
    public let group: Group
    public let detail: String
    public let lastProgressAt: String?
    public let createdAt: String
    public let nextWakeAt: String?
    public let progress: Progress
    public let nextAction: String
    public let prURL: String?
    public let evidence: [String]

    public static func webURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }

    public static func date(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

public enum WorkitOverviewError: LocalizedError {
    case configuration, unavailable, invalidResponse
    public var errorDescription: String? {
        switch self {
        case .configuration: "Configure Workit’s absolute invocation and stateDirectory in ~/.banyan/workit.json."
        case .unavailable: "Workit could not refresh. Check its executable and state directory, then retry."
        case .invalidResponse: "Workit returned an unsupported job summary. Update Workit to a version supporting job overview, then retry."
        }
    }
}

public protocol WorkitOverviewClient: Sendable {
    func fetch() async throws -> WorkitOverview
}

public struct WorkitCommandOverviewClient: WorkitOverviewClient {
    public let host: HostRuntimeContext
    public init(host: HostRuntimeContext) { self.host = host }

    public func fetch() async throws -> WorkitOverview {
        let config: WorkitCommandPauseClient.Configuration
        do {
            config = try JSONDecoder().decode(WorkitCommandPauseClient.Configuration.self,
                from: Data(contentsOf: host.homeDirectory.appendingPathComponent(".banyan/workit.json")))
        } catch { throw WorkitOverviewError.configuration }
        guard let executable = config.invocation.first, (executable as NSString).isAbsolutePath,
              FileManager.default.isExecutableFile(atPath: executable),
              !config.invocation.contains(where: { $0.contains("\0") }),
              (config.stateDirectory as NSString).isAbsolutePath, !config.stateDirectory.contains("\0") else {
            throw WorkitOverviewError.configuration
        }
        var environment = host.environment
        environment["WORKIT_STATE_DIR"] = config.stateDirectory
        let output: SubprocessRunner.Output
        do {
            output = try await SubprocessRunner.runAsync(arguments: config.invocation + ["job", "overview", "--format", "json"],
                cwd: host.homeDirectory.path, environment: environment, timeout: 30, standardInput: FileHandle.nullDevice)
        } catch is CancellationError { throw CancellationError() }
        catch { throw WorkitOverviewError.unavailable }
        guard output.terminationStatus == 0 else { throw WorkitOverviewError.unavailable }
        do { return try WorkitOverview.decode(output.standardOutput) }
        catch { throw WorkitOverviewError.invalidResponse }
    }
}
