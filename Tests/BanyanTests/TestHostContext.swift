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
