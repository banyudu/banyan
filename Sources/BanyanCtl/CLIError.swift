import BanyanCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum CLIError: LocalizedError {
    case message(String)
    case http(Int)
    case serverUnavailable

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .http(let statusCode): return "server returned HTTP \(statusCode)"
        case .serverUnavailable: return "Banyan control server is unavailable"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .message: return ExitCode.badInput
        case .http(let statusCode):
            if statusCode == 401 {
                return ExitCode.badInput
            }
            if statusCode == 404 {
                return ExitCode.notFound
            }
            if statusCode == 409 {
                return ExitCode.temporaryFailure
            }
            return ExitCode.badInput
        case .serverUnavailable: return ExitCode.serverUnavailable
        }
    }
}

enum ExitCode {
    static let success: Int32 = 0
    static let badInput: Int32 = 64
    static let notFound: Int32 = 66
    static let serverUnavailable: Int32 = 69
    /// EX_TEMPFAIL: the request was well-formed but refused for now — a
    /// suggestion whose key is still suppressed, or one that arrived while
    /// another is waiting for a decision. Scheduled callers should skip and
    /// retry rather than treat it as a broken invocation.
    static let temporaryFailure: Int32 = 75
}
