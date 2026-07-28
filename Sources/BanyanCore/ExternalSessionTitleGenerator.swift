import Foundation

/// Generates an optional session title through the user's configured command.
/// The command receives a JSON description of the session on standard input and
/// returns the title on its first output line.
public enum ExternalSessionTitleGenerator {
    public static var isConfigured: Bool {
        configuredCommand != nil
    }

    public static func generateTitle(for context: SessionTitleContext) -> String? {
        guard let command = configuredCommand else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            if let payload = try? JSONSerialization.data(withJSONObject: payload(for: context), options: [.sortedKeys]) {
                stdin.fileHandleForWriting.write(payload)
            }
            try? stdin.fileHandleForWriting.close()
        } catch {
            return nil
        }

        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            process.waitUntilExit()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 2.0) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .components(separatedBy: .newlines)
            .first
        return output.flatMap(SessionTitleGenerator.sanitizeTitle)
    }

    private static var configuredCommand: String? {
        let environmentValue = ProcessInfo.processInfo.environment["BANYAN_TITLE_COMMAND"]
        let defaultsValue = UserDefaults.standard.string(forKey: "titleGeneratorCommand")
        let value = environmentValue ?? defaultsValue
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func payload(for context: SessionTitleContext) -> [String: Any] {
        [
            "id": context.id,
            "baseTitle": context.baseTitle,
            "cwd": context.cwd,
            "project": context.project,
            "branch": context.branch ?? "",
            "command": context.command,
            "reportedTitle": context.reportedTitle ?? "",
            "provider": context.provider?.rawValue ?? "",
            "providerName": context.provider?.displayName ?? ""
        ]
    }
}
