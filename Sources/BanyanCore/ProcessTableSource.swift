import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// An executable and the argument line it was launched with, as the process
/// table reports them.
struct ProcessCommandLine: Sendable {
    let name: String
    let arguments: String
}

/// One process as the kernel lists it, before any agent classification.
///
/// The command line is deliberately *not* part of a listing. Reading argv costs
/// a syscall per process, and a supervisor tick only ever inspects the few dozen
/// processes below a pane's root PID, so it is fetched when a row is actually
/// consulted rather than for all ~900 processes on the machine.
struct ProcessTableRow: Sendable {
    let pid: Int
    let parentPID: Int
    let state: String
    let elapsed: TimeInterval
    /// The kernel's accounting name (`p_comm`), truncated to 16 characters.
    /// Only used to name a process whose argv cannot be read — a zombie, or one
    /// belonging to another user.
    let accountingName: String
    /// Set when the source already produced the command line (the `ps` reader,
    /// or a caller-supplied table). `nil` means "ask the kernel on first use".
    let resolvedCommand: ProcessCommandLine?
}

/// Reads the machine's process table.
///
/// On Darwin this is `sysctl(KERN_PROC_ALL)` plus `KERN_PROCARGS2`, which is
/// ~650x cheaper than spawning `/bin/ps` and — unlike `ps -o comm=`, whose
/// output the kernel truncates to 16 characters — reports the full executable
/// path. `ps` remains the reader on other platforms.
enum ProcessTableSource {
    static func rows() -> [ProcessTableRow] {
        #if canImport(Darwin)
        // An empty table is never a real answer — the reader itself failed — so
        // fall back rather than report that nothing is running.
        let rows = kernelRows()
        return rows.isEmpty ? processStatusRows() : rows
        #else
        return processStatusRows()
        #endif
    }

    /// Command lines for the given PIDs. Missing entries mean the process is
    /// gone or its argv is unreadable; callers fall back to the accounting name.
    static func commandLines(forPIDs pids: [Int]) -> [Int: ProcessCommandLine] {
        #if canImport(Darwin)
        guard !pids.isEmpty, let capacity = argumentBufferCapacity else { return [:] }

        // One buffer for the whole batch. `KERN_ARGMAX` is a megabyte, so a
        // per-process allocation would dominate the syscall it serves.
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: capacity)
        defer { buffer.deallocate() }

        var result: [Int: ProcessCommandLine] = [:]
        result.reserveCapacity(pids.count)
        for pid in pids {
            if let command = kernelCommandLine(pid: pid, buffer: buffer) {
                result[pid] = command
            }
        }
        return result
        #else
        _ = pids
        return [:]
        #endif
    }
}

#if canImport(Darwin)

private extension ProcessTableSource {
    static let argumentBufferCapacity: Int? = {
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return nil }
        return Int(argmax)
    }()

    static func kernelRows() -> [ProcessTableRow] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        let stride = MemoryLayout<kinfo_proc>.stride

        // The table can grow between sizing and reading it, so ask for the size,
        // allocate with slack, and retry once if the kernel still says the buffer
        // is too small.
        for _ in 0..<2 {
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

            var entries = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
            var capacity = entries.count * stride
            let status = entries.withUnsafeMutableBytes { raw in
                sysctl(&mib, 4, raw.baseAddress, &capacity, nil, 0)
            }
            if status != 0 {
                guard errno == ENOMEM else { return [] }
                continue
            }
            let now = Date().timeIntervalSince1970
            return entries.prefix(capacity / stride).compactMap { entry in
                row(from: entry, now: now)
            }
        }
        return []
    }

    static func row(from entry: kinfo_proc, now: TimeInterval) -> ProcessTableRow? {
        let pid = Int(entry.kp_proc.p_pid)
        guard pid > 0 else { return nil }

        let startedAt = TimeInterval(entry.kp_proc.p_starttime.tv_sec)
            + TimeInterval(entry.kp_proc.p_starttime.tv_usec) / 1_000_000
        var accountingName = entry.kp_proc.p_comm
        let name = withUnsafeBytes(of: &accountingName) { raw -> String in
            let bytes = raw.bindMemory(to: UInt8.self)
            let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
            return String(decoding: bytes[bytes.startIndex..<end], as: UTF8.self)
        }

        return ProcessTableRow(
            pid: pid,
            parentPID: Int(entry.kp_eproc.e_ppid),
            state: stateName(entry.kp_proc.p_stat),
            elapsed: max(0, now - startedAt),
            accountingName: name,
            resolvedCommand: nil
        )
    }

    /// The kernel's primary process state. This is `p_stat`, not the flag-laden
    /// `STAT` string `ps` prints — nothing in the supervisor reads the flags.
    static func stateName(_ stat: CChar) -> String {
        switch Int32(stat) {
        case SIDL: return "I"
        case SRUN: return "R"
        case SSLEEP: return "S"
        case SSTOP: return "T"
        case SZOMB: return "Z"
        default: return "?"
        }
    }

    /// `KERN_PROCARGS2` lays out `[argc][exec path][NUL padding][argv…][env…]`.
    /// Fails for zombies (their argv is already freed) and for processes owned by
    /// another user, which is why callers keep a fallback name.
    static func kernelCommandLine(pid: Int, buffer: UnsafeMutableBufferPointer<UInt8>) -> ProcessCommandLine? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, Int32(pid)]
        var length = buffer.count
        guard sysctl(&mib, 3, buffer.baseAddress, &length, nil, 0) == 0,
              length > MemoryLayout<Int32>.size
        else {
            return nil
        }

        guard let base = buffer.baseAddress else { return nil }
        var argumentCount: Int32 = 0
        memcpy(&argumentCount, base, MemoryLayout<Int32>.size)
        guard argumentCount > 0 else { return nil }

        var index = MemoryLayout<Int32>.size
        let executableStart = index
        while index < length, buffer[index] != 0 { index += 1 }
        let executable = String(decoding: buffer[executableStart..<index], as: UTF8.self)
        guard !executable.isEmpty else { return nil }

        while index < length, buffer[index] == 0 { index += 1 }

        var arguments: [String] = []
        arguments.reserveCapacity(Int(argumentCount))
        while index < length, arguments.count < Int(argumentCount) {
            let start = index
            while index < length, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }

        return ProcessCommandLine(
            name: executable,
            arguments: arguments.joined(separator: " ")
        )
    }
}

#endif

extension ProcessTableSource {
    /// `ps` reader, used where the kernel process table is not available.
    /// Bounded by a timeout: an unbounded `waitUntilExit()` here stalled whole
    /// supervisor ticks for tens of seconds when the machine was loaded.
    static func processStatusRows() -> [ProcessTableRow] {
        let output: Data
        do {
            let result = try SubprocessRunner.run(
                arguments: ["ps", "-axo", "pid=,ppid=,stat=,etime=,comm=,command="],
                cwd: FileManager.default.currentDirectoryPath,
                environment: ProcessInfo.processInfo.environment,
                timeout: 5
            )
            guard result.terminationStatus == 0 else { return [] }
            output = result.standardOutput
        } catch {
            return []
        }

        return (String(data: output, encoding: .utf8) ?? "")
            .split(separator: "\n")
            .compactMap(processStatusRow)
    }

    private static func processStatusRow(_ line: Substring) -> ProcessTableRow? {
        let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        guard parts.count >= 6,
              let pid = Int(parts[0]),
              let parentPID = Int(parts[1]),
              let elapsed = parseElapsedTime(parts[3])
        else {
            return nil
        }

        let name = String(parts[4])
        return ProcessTableRow(
            pid: pid,
            parentPID: parentPID,
            state: String(parts[2]),
            elapsed: elapsed,
            accountingName: name,
            resolvedCommand: ProcessCommandLine(
                name: name,
                // `ps` pads its columns, so the tail carries leading whitespace.
                arguments: String(parts[5]).trimmingCharacters(in: .whitespaces)
            )
        )
    }

    static func parseElapsedTime(_ value: Substring) -> TimeInterval? {
        let dayAndTime = value.split(separator: "-", maxSplits: 1)
        let dayCount: Int
        let timePart: Substring
        if dayAndTime.count == 2 {
            guard let days = Int(dayAndTime[0]) else { return nil }
            dayCount = days
            timePart = dayAndTime[1]
        } else {
            dayCount = 0
            timePart = value
        }

        let components = timePart.split(separator: ":").compactMap { Int($0) }
        guard components.count == 2 || components.count == 3 else { return nil }

        let seconds: Int
        if components.count == 3 {
            seconds = components[0] * 3600 + components[1] * 60 + components[2]
        } else {
            seconds = components[0] * 60 + components[1]
        }
        return TimeInterval(dayCount * 86_400 + seconds)
    }
}
