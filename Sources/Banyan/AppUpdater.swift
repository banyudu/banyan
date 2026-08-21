import AppKit
import Combine
import Foundation

struct AppVersion: Comparable, Equatable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [Identifier]

    enum Identifier: Equatable, Sendable {
        case numeric(Int)
        case text(String)
    }

    init?(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutPrefix = value.first == "v" || value.first == "V"
            ? String(value.dropFirst())
            : value
        let parts = withoutPrefix.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(numbers.count),
              numbers.allSatisfy({ Int($0) != nil }) else {
            return nil
        }

        major = Int(numbers[0]) ?? 0
        minor = numbers.count > 1 ? Int(numbers[1]) ?? 0 : 0
        patch = numbers.count > 2 ? Int(numbers[2]) ?? 0 : 0
        if parts.count == 2 {
            let identifiers = parts[1].split(separator: ".", omittingEmptySubsequences: false)
            guard !identifiers.isEmpty, !identifiers.contains(where: { $0.isEmpty }) else {
                return nil
            }
            prerelease = identifiers.map { value in
                Int(value).map(Identifier.numeric) ?? .text(String(value))
            }
        } else {
            prerelease = []
        }
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }

        for (left, right) in zip(lhs.prerelease, rhs.prerelease) {
            switch (left, right) {
            case let (.numeric(left), .numeric(right)):
                if left != right { return left < right }
            case (.numeric, .text):
                return true
            case (.text, .numeric):
                return false
            case let (.text(left), .text(right)):
                if left != right { return left < right }
            }
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

struct AppUpdateRelease: Decodable, Equatable, Sendable {
    let tagName: String
    let name: String
    let htmlURL: URL
    let assets: [Asset]

    struct Asset: Decodable, Equatable, Sendable {
        let name: String
        let browserDownloadURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlURL = "html_url"
        case assets
    }

    var version: AppVersion? { AppVersion(tagName) }

    var packageAsset: Asset? {
        assets.first { $0.name.lowercased().hasSuffix(".dmg") }
    }

    var displayName: String {
        version.map { "Banyan \($0.major).\($0.minor).\($0.patch)" } ?? name
    }
}

struct PendingAppUpdate: Identifiable, Equatable {
    let release: AppUpdateRelease
    let downloadedPackageURL: URL

    var id: String { release.tagName }
}

enum AppUpdatePrompt: Identifiable {
    case available(PendingAppUpdate)
    case failed(String)

    var id: String {
        switch self {
        case .available(let update): return "available-\(update.id)"
        case .failed(let message): return "failed-\(message)"
        }
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false
    @Published private(set) var isInstalling = false
    @Published private(set) var pendingUpdate: PendingAppUpdate?
    @Published var prompt: AppUpdatePrompt?

    private let session: URLSession
    private let currentVersion: AppVersion
    private let bundleURL: URL
    private var hasCheckedAutomatically = false

    init(
        session: URLSession = .shared,
        bundle: Bundle = .main
    ) {
        self.session = session
        self.currentVersion = AppVersion(
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.2.5"
        ) ?? AppVersion("0.2.5")!
        self.bundleURL = bundle.bundleURL
    }

    func checkForUpdates(userInitiated: Bool = false) {
        if !userInitiated {
            guard !hasCheckedAutomatically else { return }
            hasCheckedAutomatically = true
        }
        guard !isChecking, !isDownloading, !isInstalling else { return }

        isChecking = true
        Task {
            do {
                let release = try await fetchLatestRelease()
                guard let version = release.version,
                      version > currentVersion,
                      release.packageAsset != nil else {
                    isChecking = false
                    if userInitiated {
                        prompt = .failed("Banyan is already up to date.")
                    }
                    return
                }

                isChecking = false
                isDownloading = true
                let packageURL = try await downloadPackage(for: release)
                isDownloading = false
                let update = PendingAppUpdate(release: release, downloadedPackageURL: packageURL)
                pendingUpdate = update
                prompt = .available(update)
            } catch {
                isChecking = false
                isDownloading = false
                if userInitiated {
                    prompt = .failed("Could not check for updates: \(error.localizedDescription)")
                }
            }
        }
    }

    func install(_ update: PendingAppUpdate) {
        guard !isInstalling else { return }
        isInstalling = true
        prompt = nil
        Task {
            do {
                try await AppUpdateInstaller.install(
                    downloadedPackageURL: update.downloadedPackageURL,
                    applicationURL: bundleURL,
                    processID: ProcessInfo.processInfo.processIdentifier
                )
                NSApp.terminate(nil)
            } catch {
                isInstalling = false
                prompt = .failed("Could not install \(update.release.displayName): \(error.localizedDescription)")
            }
        }
    }

    private func fetchLatestRelease() async throws -> AppUpdateRelease {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/banyudu/banyan/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Banyan/\(currentVersion.major).\(currentVersion.minor).\(currentVersion.patch)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw UpdateError.invalidResponse
        }
        return try JSONDecoder().decode(AppUpdateRelease.self, from: data)
    }

    private func downloadPackage(for release: AppUpdateRelease) async throws -> URL {
        guard let asset = release.packageAsset else { throw UpdateError.packageNotFound }
        var request = URLRequest(url: asset.browserDownloadURL)
        request.setValue("Banyan/\(currentVersion.major).\(currentVersion.minor).\(currentVersion.patch)", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await session.download(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw UpdateError.invalidResponse
        }

        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("Banyan-Update-\(UUID().uuidString).dmg")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }
}

private enum UpdateError: LocalizedError {
    case invalidResponse
    case packageNotFound

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub returned an invalid response."
        case .packageNotFound: return "The latest GitHub release does not contain a DMG package."
        }
    }
}

private enum AppUpdateInstaller {
    static func install(downloadedPackageURL: URL, applicationURL: URL, processID: Int32) async throws {
        let stagedApplicationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Banyan-Staged-\(UUID().uuidString).app")
        try await Task.detached {
            try stageApplication(from: downloadedPackageURL, to: stagedApplicationURL)
        }.value

        let script = """
        #!/bin/sh
        set -eu
        while kill -0 \(processID) 2>/dev/null; do sleep 0.2; done
        rm -rf \(shellQuote(applicationURL.path))
        ditto \(shellQuote(stagedApplicationURL.path)) \(shellQuote(applicationURL.path))
        open \(shellQuote(applicationURL.path))
        rm -rf \(shellQuote(stagedApplicationURL.path))
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }

    private static func stageApplication(from packageURL: URL, to destinationURL: URL) throws {
        let mountURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Banyan-Mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mountURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: mountURL) }

        try run("/usr/bin/hdiutil", arguments: [
            "attach", packageURL.path, "-nobrowse", "-readonly", "-mountpoint", mountURL.path
        ])
        defer { try? run("/usr/bin/hdiutil", arguments: ["detach", mountURL.path, "-force"]) }

        let mountedApplicationURL = mountURL.appendingPathComponent("Banyan.app")
        guard FileManager.default.fileExists(atPath: mountedApplicationURL.path) else {
            throw UpdateError.packageNotFound
        }
        try? FileManager.default.removeItem(at: destinationURL)
        try FileManager.default.copyItem(at: mountedApplicationURL, to: destinationURL)
        try run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", destinationURL.path])
    }

    private static func run(_ executablePath: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.invalidResponse }
    }

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
