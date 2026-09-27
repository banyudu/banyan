import BanyanCore
import Foundation

let banyanTestHost = HostRuntimeContext(
    environment: ProcessInfo.processInfo.environment,
    homeDirectory: URL(fileURLWithPath: NSHomeDirectory()),
    currentDirectory: FileManager.default.currentDirectoryPath
)

let banyanTestTelemetry = PerformanceTelemetry(
    store: PerformanceEventStore(
        databaseURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("banyan-tests-telemetry.sqlite")
    )
)

let banyanTestTmuxBackend = TmuxBackend(
    environment: banyanTestHost.environment,
    workingDirectory: banyanTestHost.currentDirectory,
    // A socket of its own. A store built on this backend runs the same launch
    // reap the app does, and on the app's socket that reap sees every live
    // session, matches none of the fixture's rows, and kills the lot.
    socketName: "banyan-test"
)
