import Foundation
import PuckSwift

@main struct Example {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        let client = args.first.map { PuckClient(socketPath: $0) } ?? PuckClient()
        let capabilities = try await client.capabilities()
        print("Puck protocol \(capabilities.version.major).\(capabilities.version.minor), default \(capabilities.defaultEngine.rawValue)")
        if args.count > 1 {
            let page = try await client.history(args[1], limit: 10)
            for item in page.items.reversed() { print("\(item.kind): \(item.text)") }
            print("More history: \(page.nextCursor != nil)")
        } else {
            for session in try await client.list() { print("\(session.id)\t\(session.engine)\t\(session.position)") }
        }
    }
}
