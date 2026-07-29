import Foundation

/// Host-specific inputs supplied by a frontend at its composition boundary.
/// Shared runtime code should consume this value rather than rediscovering the
/// process environment or filesystem locations.
public struct HostRuntimeContext: Sendable {
    public let environment: [String: String]
    public let homeDirectory: URL
    public let currentDirectory: String

    public init(
        environment: [String: String],
        homeDirectory: URL,
        currentDirectory: String
    ) {
        self.environment = environment
        self.homeDirectory = homeDirectory
        self.currentDirectory = currentDirectory
    }
}
