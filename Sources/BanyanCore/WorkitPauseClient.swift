import Foundation

public struct WorkitPauseRequest: Equatable, Sendable {
    public let jobID: String
    public let expectedRevision: Int
    public let sessionID: String
    public let detail: String

    public init(jobID: String, expectedRevision: Int, sessionID: String, detail: String) {
        self.jobID = jobID; self.expectedRevision = expectedRevision
        self.sessionID = sessionID; self.detail = detail
    }

    public var arguments: [String] {
        ["job", "pause", jobID, "--detail", detail, "--expected-revision", String(expectedRevision),
         "--expected-session-id", sessionID]
    }
}

/// The relevant fields of Workit's resulting job JSON (not Banyan's projection).
public struct WorkitPausedJob: Decodable, Equatable, Sendable {
    public let id: String
    public let sessionID: String
    public let revision: Int
    public let stage: String

    public init(id: String, sessionID: String, revision: Int, stage: String) {
        self.id = id; self.sessionID = sessionID; self.revision = revision; self.stage = stage
    }

    public func validate(for request: WorkitPauseRequest) throws {
        guard id == request.jobID, sessionID == request.sessionID,
              revision > request.expectedRevision, stage == "paused" else {
            throw WorkflowError.refused("Workit did not acknowledge the exact job/session with a newer paused revision. The terminal remains open. Inspect the job with the configured Workit CLI before retrying.")
        }
    }

    public func matches(_ workflow: SessionWorkflow?) -> Bool {
        guard let workflow else { return false }
        return workflow.owner == "workit" && workflow.jobID == id
            && workflow.revision == revision && workflow.state == .paused
    }
}

public protocol WorkitPauseClient: Sendable {
    func pause(_ request: WorkitPauseRequest) async throws -> WorkitPausedJob
}

/// Only host-owned configuration supplies executable argv and state location.
/// Never use a session command, issue body, project config, or job's controlCommand.
public struct WorkitCommandPauseClient: WorkitPauseClient {
    public struct Configuration: Codable, Sendable {
        public let invocation: [String]
        public let stateDirectory: String

        public init(invocation: [String], stateDirectory: String) {
            self.invocation = invocation; self.stateDirectory = stateDirectory
        }
    }

    public let host: HostRuntimeContext
    public init(host: HostRuntimeContext) { self.host = host }

    public func pause(_ request: WorkitPauseRequest) async throws -> WorkitPausedJob {
        let config: Configuration
        do {
            config = try JSONDecoder().decode(Configuration.self,
                from: Data(contentsOf: host.homeDirectory.appendingPathComponent(".banyan/workit.json")))
        } catch {
            throw WorkflowError.refused("Configure a trusted Workit invocation and stateDirectory in ~/.banyan/workit.json, then retry. The terminal remains open.")
        }
        guard let executable = config.invocation.first, (executable as NSString).isAbsolutePath,
              !config.invocation.contains(where: { $0.contains("\0") }),
              (config.stateDirectory as NSString).isAbsolutePath, !config.stateDirectory.contains("\0") else {
            throw WorkflowError.refused("Workit configuration needs an absolute executable path and absolute stateDirectory; invocation is an argv array. Fix ~/.banyan/workit.json and retry.")
        }
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw WorkflowError.refused("The configured Workit executable is missing or not executable. Install a CLI supporting --expected-revision and --expected-session-id, or fix ~/.banyan/workit.json, then retry. The terminal remains open.")
        }
        var environment = host.environment
        environment["WORKIT_STATE_DIR"] = config.stateDirectory
        let output: SubprocessRunner.Output
        do {
            output = try await SubprocessRunner.runAsync(arguments: config.invocation + request.arguments,
                cwd: host.homeDirectory.path, environment: environment, timeout: 30,
                standardInput: FileHandle.nullDevice)
        } catch {
            throw WorkflowError.refused("The Workit pause command could not finish. The terminal remains open; inspect the job with the configured CLI before retrying because a pause may already be saved.")
        }
        guard output.terminationStatus == 0 else {
            // Do not echo CLI output: it can contain private job/issue content.
            throw WorkflowError.refused("Workit pause failed (exit \(output.terminationStatus)). The terminal remains open. Check the configured state directory and job binding, and upgrade Workit if it lacks --expected-revision or --expected-session-id. A pause may already be saved; inspect the job before retrying.")
        }
        let job: WorkitPausedJob
        do {
            guard output.standardOutput.count <= 1024 * 1024 else { throw WorkflowError.refused("oversized response") }
            job = try JSONDecoder().decode(WorkitPausedJob.self, from: output.standardOutput)
        } catch {
            throw WorkflowError.refused("Workit returned an unreadable pause acknowledgement. The terminal remains open; inspect the job with the configured CLI before retrying because a pause may already be saved.")
        }
        try job.validate(for: request)
        return job
    }
}
