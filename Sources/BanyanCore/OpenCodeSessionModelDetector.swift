import CSQLite
import Foundation

/// The runtime identity OpenCode records for an active session.
///
/// `modelID` is exact when it came from the SQLite session row. The status-bar
/// fallback only has OpenCode's display name, which is still useful as a label
/// but must not be mistaken for a stable model identifier.
public struct OpenCodeRuntimeIdentity: Sendable, Equatable {
    public let provider: CodingAgentProvider?
    public let modelID: String
    public let isExactModelID: Bool

    public init(provider: CodingAgentProvider?, modelID: String, isExactModelID: Bool) {
        self.provider = provider
        self.modelID = modelID
        self.isExactModelID = isExactModelID
    }
}

/// Resolves OpenCode's currently selected model without accessing transcripts.
///
/// OpenCode keeps the live selection on its `session` row, including updates
/// made by its model picker. The database is opened with `mode=ro` and this type
/// issues one parameterized query against that table only.
public struct OpenCodeSessionModelDetector: Sendable {
    private static let sessionStartTolerance: TimeInterval = 60

    public init() {}

    public func resolve(
        directory: String,
        sessionStartedAt: Date,
        environment: [String: String]
    ) -> OpenCodeRuntimeIdentity? {
        guard !directory.isEmpty,
              let databaseURL = databaseURL(environment: environment),
              FileManager.default.fileExists(atPath: databaseURL.path),
              let database = openReadOnly(databaseURL)
        else {
            return nil
        }
        defer { sqlite3_close(database) }

        let directories = normalizedDirectories(for: directory)
        guard !directories.isEmpty else { return nil }

        let placeholders = Array(repeating: "?", count: directories.count).joined(separator: ", ")
        let sql = """
        SELECT model
        FROM session
        WHERE directory IN (\(placeholders))
          AND time_created >= ?
          AND model IS NOT NULL
        ORDER BY time_updated DESC
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        for (index, candidate) in directories.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), candidate, -1, sqliteTransient)
        }
        let earliestSessionTime = Int64((sessionStartedAt.timeIntervalSince1970 - Self.sessionStartTolerance) * 1_000)
        sqlite3_bind_int64(statement, Int32(directories.count + 1), earliestSessionTime)

        guard sqlite3_step(statement) == SQLITE_ROW,
              let modelJSON = columnText(statement, 0),
              let model = try? JSONDecoder().decode(Model.self, from: Data(modelJSON.utf8)),
              !model.id.isEmpty
        else {
            return nil
        }
        return OpenCodeRuntimeIdentity(
            provider: CodingAgentProvider.runtimeProvider(modelID: model.id, providerID: model.providerID),
            modelID: model.id,
            isExactModelID: true
        )
    }

    /// Parses OpenCode's static status line only. Callers must first establish
    /// that the pane contains a live OpenCode process, so other agents' dot-
    /// separated status lines cannot be misidentified.
    public static func statusBarIdentity(in visibleText: String) -> OpenCodeRuntimeIdentity? {
        let lines = visibleText.split(separator: "\n", omittingEmptySubsequences: false)
        for line in lines.reversed() {
            let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.localizedCaseInsensitiveContains("opencode"),
                  let separator = text.range(of: "·")
            else {
                continue
            }
            let afterMode = text[separator.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let variantStart = afterMode.range(of: " ("),
                  variantStart.lowerBound > afterMode.startIndex
            else {
                continue
            }
            let modelName = String(afterMode[..<variantStart.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelName.isEmpty else { continue }
            return OpenCodeRuntimeIdentity(
                provider: CodingAgentProvider.runtimeProvider(modelID: modelName, providerID: nil),
                modelID: modelName,
                isExactModelID: false
            )
        }
        return nil
    }

    public func databaseURL(environment: [String: String]) -> URL? {
        if let override = environment["OPENCODE_DB"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let dataDirectory: String
        if let xdgDataHome = environment["XDG_DATA_HOME"], !xdgDataHome.isEmpty {
            dataDirectory = (xdgDataHome as NSString).expandingTildeInPath
        } else if let home = environment["HOME"], !home.isEmpty {
            dataDirectory = URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
                .appendingPathComponent(".local/share")
                .path
        } else {
            dataDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/share")
                .path
        }
        return URL(fileURLWithPath: dataDirectory)
            .appendingPathComponent("opencode/opencode.db")
    }

    private func openReadOnly(_ url: URL) -> OpaquePointer? {
        var database: OpaquePointer?
        let uri = "\(url.absoluteString)?mode=ro"
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(uri, &database, flags, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            return nil
        }
        return database
    }

    private func normalizedDirectories(for directory: String) -> [String] {
        let original = (directory as NSString).standardizingPath
        let resolved = URL(fileURLWithPath: original).resolvingSymlinksInPath().path
        return Array(Set([original, resolved]))
    }

    private func columnText(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: value)
    }

    private struct Model: Decodable {
        let id: String
        let providerID: String?
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
