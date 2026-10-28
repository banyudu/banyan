import BanyanCore
import Combine
import CryptoKit
import Foundation

@MainActor
final class SlackIntegrationController: ObservableObject {
    enum Connection: Equatable {
        case disabled, stopped, starting, connecting, connected, offline, stopping, failed(String)
        var label: String {
            switch self {
            case .disabled: return "Disabled"
            case .stopped: return "Stopped"
            case .starting: return "Starting"
            case .connecting: return "Connecting"
            case .connected: return "Connected"
            case .offline: return "Offline — reconnecting"
            case .stopping: return "Stopping"
            case .failed(let message): return message
            }
        }
    }
    @Published private(set) var connection: Connection = .disabled
    @Published private(set) var allowed: [CodexRemotePrincipal]
    @Published private(set) var enabled: Bool
    @Published var pythonPath: String {
        didSet { if let key = pythonDefaultsKey { pythonDefaults?.set(pythonPath, forKey: key) } }
    }
    private let remote: CodexRemoteControl
    private let credentials: any SlackCredentialStoring
    private let launcher: any SlackConnectorLaunching
    private let host: HostRuntimeContext
    private let script: URL
    private let policyFile: URL
    private let stateFile: URL
    private let tokenFile: URL
    private var controlURL: String
    private let pythonDefaults: UserDefaults?
    private let pythonDefaultsKey: String?
    private let managedDefaultsKey: String?
    private var managedExplicitly: Bool
    private var child: (any SlackConnectorRunning)?
    private var childID: UUID?
    private var intent: UInt64 = 0
    private var starting = false
    private var restartAfterExit = false
    private var serverReady = false

    init(remote: CodexRemoteControl, host: HostRuntimeContext, script: URL,
         credentials: any SlackCredentialStoring, launcher: any SlackConnectorLaunching,
         pythonPath: String, controlURL: String, tokenFile: URL,
         pythonDefaults: UserDefaults? = nil, pythonDefaultsKey: String? = nil,
         managedDefaultsKey: String? = nil, managedExplicitly: Bool = false) {
        self.remote = remote; self.host = host; self.script = script
        self.credentials = credentials; self.launcher = launcher; self.pythonPath = pythonPath
        self.pythonDefaults = pythonDefaults; self.pythonDefaultsKey = pythonDefaultsKey
        self.managedDefaultsKey = managedDefaultsKey; self.managedExplicitly = managedExplicitly
        self.controlURL = controlURL; self.tokenFile = tokenFile
        self.allowed = remote.policy.allowed; self.enabled = remote.policy.enabled
        self.policyFile = BanyanDataDirectory.url(for: "Banyan/slack-connector/policy.json", environment: host.environment, homeDirectory: host.homeDirectory)
        self.stateFile = BanyanDataDirectory.url(for: "Banyan/slack-connector/state.json", environment: host.environment, homeDirectory: host.homeDirectory)
        connection = remote.policy.enabled ? .stopped : .disabled
    }

    static func live(remote: CodexRemoteControl, host: HostRuntimeContext) -> SlackIntegrationController {
        let bundlePath = Bundle.main.bundleURL.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(bundlePath.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Slack/slack-connector.py")
        let development = URL(fileURLWithPath: host.currentDirectory).appendingPathComponent("scripts/slack-connector.py")
        let script = bundled.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? development
        let defaultsKey = "slackConnectorPython.\(digest)"
        let managedKey = "slackConnectorManaged.\(digest)"
        let defaultPython = host.homeDirectory.appendingPathComponent(".local/share/banyan-slack/venv/bin/python").path
        let python = UserDefaults.standard.string(forKey: defaultsKey) ?? defaultPython
        let port = LabEnvironment.controlPort(from: host.environment) ?? 7842
        return SlackIntegrationController(remote: remote, host: host, script: script,
            credentials: SlackKeychainCredentialStore(service: "app.banyan.slack.\(digest)"), launcher: LocalSlackConnectorLauncher(),
            pythonPath: python, controlURL: "http://127.0.0.1:\(port)",
            tokenFile: ControlToken.tokenFileURL(environment: host.environment, homeDirectory: host.homeDirectory),
            pythonDefaults: .standard, pythonDefaultsKey: defaultsKey,
            managedDefaultsKey: managedKey, managedExplicitly: UserDefaults.standard.bool(forKey: managedKey))
    }

    func saveCredentials(botToken: String, appToken: String) async throws {
        guard !botToken.isEmpty, !appToken.isEmpty,
              !botToken.contains(where: \.isWhitespace), !appToken.contains(where: \.isWhitespace) else { throw SlackCredentialError.invalid }
        let store = credentials
        try await Task.detached(priority: .userInitiated) { try store.save(.init(botToken: botToken, appToken: appToken)) }.value
    }

    func setAllowlist(_ entries: [CodexRemotePrincipal]) throws {
        guard child == nil, !starting, !remote.policy.enabled else { throw Failure.stopFirst }
        guard entries.count <= 256, entries.allSatisfy({ Self.validID($0.workspace) && Self.validID($0.channel) && Self.validID($0.user) }),
              Set(entries.map { "\($0.workspace):\($0.channel)" }).count <= 1,
              Set(entries.map { "\($0.workspace):\($0.channel):\($0.user)" }).count == entries.count else { throw Failure.invalidPolicy }
        try remote.configure(.init(enabled: false, allowed: entries))
        allowed = entries; enabled = false
    }

    func policyChanged() {
        allowed = remote.policy.allowed
        enabled = remote.policy.enabled
        if !remote.policy.enabled, child != nil, connection != .stopping {
            intent &+= 1
            connection = .stopping
            child?.terminate()
        } else if !managedExplicitly, child == nil, !starting {
            connection = remote.policy.enabled ? (remote.isOnline ? .connected : .stopped) : .disabled
        }
    }

    func controlServerBecameReady(port: UInt16) {
        controlURL = "http://127.0.0.1:\(port)"
        serverReady = true
        if managedExplicitly && remote.policy.enabled && child == nil && !starting {
            Task { [weak self] in try? await self?.start() }
        }
    }

    func start() async throws {
        guard child == nil, !starting else { return }
        guard serverReady else { throw Failure.serverUnavailable }
        guard !allowed.isEmpty else { throw Failure.invalidPolicy }
        guard FileManager.default.isExecutableFile(atPath: pythonPath), FileManager.default.isReadableFile(atPath: script.path) else { throw Failure.missingRuntime }
        starting = true; intent &+= 1
        let currentIntent = intent
        connection = .starting
        defer { starting = false }
        do {
            let store = credentials
            let pair = try await Task.detached(priority: .userInitiated) { try store.load() }.value
            guard currentIntent == intent else { return }
            let policy = CodexRemotePolicy(enabled: true, allowed: allowed)
            try writePolicy(policy)
            managedExplicitly = true
            if let key = managedDefaultsKey { pythonDefaults?.set(true, forKey: key) }
            try remote.configure(policy)
            enabled = true
            let id = UUID()
            let specification = SlackConnectorLaunch(executable: URL(fileURLWithPath: pythonPath),
                arguments: [script.path, "start", "--config", policyFile.path, "--state", stateFile.path,
                            "--control-url", controlURL, "--token-file", tokenFile.path],
                environment: ["HOME": host.homeDirectory.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                              "PYTHONDONTWRITEBYTECODE": "1", "SLACK_BOT_TOKEN": pair.botToken, "SLACK_APP_TOKEN": pair.appToken],
                workingDirectory: script.deletingLastPathComponent())
            childID = id
            child = try launcher.launch(specification, status: { [weak self] value in self?.status(value, childID: id) },
                exited: { [weak self] code in self?.exited(code, childID: id) })
            connection = .connecting
        } catch {
            childID = nil; child = nil
            try? remote.configure(.init(enabled: false, allowed: allowed))
            enabled = remote.policy.enabled
            connection = .failed("Connector could not start. Check credentials, private channel and Python setup.")
            throw error
        }
    }

    func stop() throws {
        intent &+= 1; restartAfterExit = false
        let active = child
        if active != nil { connection = .stopping }
        var failure: Error?
        do { try remote.configure(.init(enabled: false, allowed: allowed)) } catch { failure = error }
        enabled = remote.policy.enabled
        if let active { active.terminate() } else { connection = .disabled }
        if let failure { throw failure }
    }

    func reconnect() throws {
        guard let active = child else { Task { [weak self] in try? await self?.start() }; return }
        intent &+= 1; restartAfterExit = true; connection = .stopping
        do { try remote.configure(.init(enabled: false, allowed: allowed)); enabled = false }
        catch { restartAfterExit = false; enabled = remote.policy.enabled; active.terminate(); throw error }
        active.terminate()
    }

    /// App shutdown stops the child without changing the saved enable setting.
    func stopForShutdown() { intent &+= 1; restartAfterExit = false; child?.terminate() }

    private func status(_ value: String, childID: UUID) {
        guard self.childID == childID, !restartAfterExit, connection != .stopping else { return }
        switch value {
        case "connecting": connection = .connecting
        case "connected": connection = .connected
        case "offline": connection = .offline
        default: break
        }
    }

    private func exited(_ code: Int32, childID: UUID) {
        guard self.childID == childID else { return }
        child = nil; self.childID = nil
        if restartAfterExit {
            restartAfterExit = false; connection = .stopped
            Task { [weak self] in try? await self?.start() }
        } else if remote.policy.enabled {
            connection = .failed("Connector stopped. Check Python setup and Slack permissions.")
        } else { connection = .disabled }
    }

    private func writePolicy(_ policy: CodexRemotePolicy) throws {
        let data = try JSONEncoder().encode(policy)
        let directory = policyFile.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: policyFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: policyFile.path)
    }
    private static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
    }
    enum Failure: LocalizedError {
        case invalidPolicy, stopFirst, serverUnavailable, missingRuntime
        var errorDescription: String? {
            switch self {
            case .invalidPolicy: return "Add exact workspace, private channel and user IDs for one channel."
            case .stopFirst: return "Stop Slack before changing its allowlist."
            case .serverUnavailable: return "Banyan's local control server is not ready."
            case .missingRuntime: return "Install the Slack Python environment and select its interpreter."
            }
        }
    }
}
