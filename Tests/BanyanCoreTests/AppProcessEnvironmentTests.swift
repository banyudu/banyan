import Foundation
#if canImport(Darwin)
import Darwin
#endif
import Testing
@testable import BanyanCore

@Test func sharedEnvironmentBuilderParsesShellOutput() {
    let bytes = Array("\n__BANYAN_SHELL_ENV_START__\nFOO=bar\0PATH=/custom/bin\0".utf8)

    #expect(
        AppProcessEnvironment.parseEnvironmentOutput(Data(bytes)) == [
            "FOO": "bar",
            "PATH": "/custom/bin"
        ]
    )
}

@Test func sharedEnvironmentBuilderDeduplicatesPathEntries() {
    var environment = ["PATH": "/usr/bin:/work/bin"]

    AppProcessEnvironment.mergePath(
        into: &environment,
        pathAdditions: ["/work/bin", "/local/bin"],
        shellPath: "/local/bin:/shell/bin"
    )

    #expect(environment["PATH"] == "/work/bin:/local/bin:/shell/bin:/usr/bin")
}

/// Serialized: these share `AppProcessEnvironment`'s process-wide shell cache.
@Suite(.serialized)
struct ShellEnvironmentLoadingTests {
    @Test func resolvesOncePerShellThenServesFromCache() {
        // A marker exported only by this process: it can reach the result only through a
        // real shell spawn, so its value tells us whether a second spawn happened.
        let marker = "BANYAN_TEST_SHELL_ENV_\(ProcessInfo.processInfo.processIdentifier)"
        setenv(marker, "1", 1)
        defer {
            unsetenv(marker)
            AppProcessEnvironment.resetShellEnvironmentCacheForTesting()
        }
        AppProcessEnvironment.resetShellEnvironmentCacheForTesting()

        let shell = FileManager.default.isExecutableFile(atPath: "/bin/zsh") ? "/bin/zsh" : "/bin/sh"
        let environment = ["SHELL": shell]
        let first = AppProcessEnvironment.shellEnvironment(environment: environment)
        #expect(first[marker] == "1")

        // A second spawn would observe "2"; a cache hit still reports "1".
        setenv(marker, "2", 1)
        let second = AppProcessEnvironment.shellEnvironment(environment: environment)
        #expect(second[marker] == "1")
    }

    @Test func timeoutLeavesNoParkedThreadsOrZombies() async throws {
        // A shell that never exits *and ignores SIGTERM* — the case that actually broke
        // the app. The old implementation's `terminate()` had no effect on such a child,
        // so its `waitUntilExit()` thread stayed parked forever; enough of those
        // exhausted libdispatch's 80-thread soft limit and froze the app. Only escalating
        // to SIGKILL releases it. A stub that dies on SIGTERM does not reproduce this.
        let stub = FileManager.default.temporaryDirectory
            .appendingPathComponent("banyan-hanging-shell-\(UUID().uuidString)")
        let pidLog = stub.appendingPathExtension("pids")
        try "#!/bin/sh\ntrap '' TERM\nprintf '%s\\n' \"$$\" >> \(subprocessTestQuote(pidLog.path))\nwhile :; do sleep 1; done\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        AppProcessEnvironment.shellEnvironmentTimeoutOverrideForTesting = 0.5
        defer {
            AppProcessEnvironment.shellEnvironmentTimeoutOverrideForTesting = nil
            AppProcessEnvironment.resetShellEnvironmentCacheForTesting()
            try? FileManager.default.removeItem(at: stub)
            try? FileManager.default.removeItem(at: pidLog)
        }
        AppProcessEnvironment.resetShellEnvironmentCacheForTesting()

        let attempts = 4
        let (before, after, results) = try await runBlockingTestWork {
            let before = threadCount()
            var results: [[String: String]] = []
            for _ in 0..<attempts {
                results.append(AppProcessEnvironment.shellEnvironment(environment: ["SHELL": stub.path]))
                // Force a fresh load each time rather than reusing the cached failure.
                AppProcessEnvironment.resetShellEnvironmentCacheForTesting()
            }
            return (before, threadCount(), results)
        }
        for result in results {
            #expect(result.isEmpty)
        }

        // Previously every timed-out load parked a thread permanently.
        #expect(after - before < attempts)

        // Require every shell to have installed its trap and recorded its own
        // PID, then prove those exact children were killed and reaped. This
        // cannot mistake another test's short-lived subprocess for our leak.
        let pids = try String(contentsOf: pidLog, encoding: .utf8)
            .split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        try #require(pids.count == attempts && Set(pids).count == attempts, "expected \(attempts) distinct shell PIDs, got \(pids)")
        for pid in pids {
            try #require(pid > 0)
            #expect(await waitForTestChildExit(pid), "timed-out shell pid \(pid) was not reaped")
        }
    }
}

private func threadCount() -> Int {
#if canImport(Darwin)
    var count = mach_msg_type_number_t(0)
    var threads: thread_act_array_t?
    guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else {
        return 0
    }
    for index in 0..<Int(count) {
        mach_port_deallocate(mach_task_self_, threads[index])
    }
    vm_deallocate(
        mach_task_self_,
        vm_address_t(UInt(bitPattern: threads)),
        vm_size_t(Int(count) * MemoryLayout<thread_t>.size)
    )
    return Int(count)
#elseif os(Linux)
    guard let status = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8),
          let line = status.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Threads:") }),
          let count = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last.flatMap({ Int($0) }) else {
        return 0
    }
    return count
#else
    return 0
#endif
}
