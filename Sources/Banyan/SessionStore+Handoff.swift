import BanyanCore
import Foundation
import AppKit
import SwiftUI

extension SessionStore {
    @discardableResult
    func dispatchHandoff(id: String, bypassEligibility: Bool = false) -> Bool {
        // Re-resolve at dispatch time so a handoff command installed or removed
        // after launch takes effect without restarting the app.
        let command = resolvedHandoffCommand
        isHandoffAvailable = command != nil
        guard let command,
              let session = sessions.first(where: { $0.id == id }),
              (bypassEligibility || session.canDispatchHandoff),
              !pendingHandoffJobs.contains(where: { $0.sessionID == id }) else {
            return false
        }

        let job = HandoffJob(
            id: id,
            sessionID: id,
            title: session.displayTitle,
            cwd: session.cwd,
            startedAt: Date()
        )

        do {
            try close(id: id)
        } catch {
            // The session is still open here, so say that rather than let the
            // caller's generic "could not be started" imply it was restored.
            handoffNotice = "Handoff could not be started: \(error.localizedDescription)"
            return false
        }

        pendingHandoffJobs.append(job)
        let environment = self.environment
        Task.detached(priority: .utility) { [environment, command] in
            let result = runHandoffDispatch(
                command: command,
                cwd: job.cwd,
                environment: environment
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.pendingHandoffJobs.removeAll { $0.id == job.id }
                if case .failure(let error) = result {
                    try? self.respawn(id: job.sessionID)
                    self.handoffNotice = error.notice
                }
            }
        }
        return true
    }

    func handleHandoffShortcut() {
        // The preference hides the button and the shortcut together, so a
        // stray chord should do nothing rather than accuse the user of not
        // having installed a command they deliberately turned off.
        guard enableHandoffAction else { return }
        guard isHandoffAvailable else {
            handoffNotice = "Handoff is not configured. Install an executable at ~/bin/handoff or set \(SessionHandoffPolicy.commandEnvironmentKey)."
            return
        }
        guard let session = selectedSession else {
            handoffNotice = "Select a session before starting handoff."
            return
        }
        guard !pendingHandoffJobs.contains(where: { $0.sessionID == session.id }) else {
            handoffNotice = "Handoff is already running for this session."
            return
        }
        guard dispatchHandoff(id: session.id, bypassEligibility: true) else {
            // Keep whatever reason the dispatch already reported.
            if handoffNotice == nil {
                handoffNotice = "Handoff could not be started."
            }
            return
        }
    }

    func isHandoffPending(for sessionID: String) -> Bool {
        pendingHandoffJobs.contains { $0.sessionID == sessionID }
    }

    /// The executable to dispatch, or nil when the action is off or nothing is
    /// installed. Resolved on demand so installing or removing the command
    /// takes effect without restarting the app.
    private var resolvedHandoffCommand: String? {
        guard enableHandoffAction else { return nil }
        return Self.resolveHandoffCommand(environment: environment, homeDirectory: homeDirectory)
    }

    /// Single source of truth for the handoff affordances: the button, the
    /// shortcut, and the "not configured" notice all read `isHandoffAvailable`.
    func refreshHandoffAvailability() {
        isHandoffAvailable = resolvedHandoffCommand != nil
    }

    private static func resolveHandoffCommand(
        environment: [String: String],
        homeDirectory: String
    ) -> String? {
        SessionHandoffPolicy.commandPath(
            environment: environment,
            homeDirectory: homeDirectory,
            isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }
}

private enum HandoffDispatchError: Error {
    case commandUnavailable(String)
    case failed(Int32, String)

    var notice: String {
        switch self {
        case .commandUnavailable(let message):
            return SessionHandoffPolicy.dispatchFailureNotice(exitStatus: nil, output: message)
        case .failed(let status, let output):
            return SessionHandoffPolicy.dispatchFailureNotice(exitStatus: status, output: output)
        }
    }
}

private func runHandoffDispatch(
    command: String,
    cwd: String,
    environment: [String: String]
) -> Result<Void, HandoffDispatchError> {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command, "dispatch"]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    process.environment = AppProcessEnvironment.make(
        base: environment,
        shellEnvironment: AppProcessEnvironment.shellEnvironment(environment: environment)
    )
    // Both streams share one pipe so the failure reason stays in the order the
    // command printed it, whichever stream it chose.
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    defer { pipe.closeBothEnds() }

    do {
        try process.run()
    } catch {
        return .failure(.commandUnavailable(error.localizedDescription))
    }

    // Drain while the command runs: a dispatch can outrun the 64 KiB pipe
    // buffer, and a full buffer would wedge the child before it ever exits.
    let collected = HandoffOutputBuffer()
    let reader = pipe.fileHandleForReading
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        while true {
            let chunk = reader.availableData
            if chunk.isEmpty { break }
            collected.append(chunk)
        }
        drained.signal()
    }

    process.waitUntilExit()
    drained.wait()

    guard process.terminationStatus == 0 else {
        return .failure(.failed(process.terminationStatus, collected.text()))
    }
    return .success(())
}

/// Accumulates command output across the reader thread and the caller, keeping
/// only the tail — the alert shows a handful of lines and the rest is ballast.
private final class HandoffOutputBuffer {
    private static let capacity = 8 * 1024
    private let lock = NSLock()
    var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
        if data.count > Self.capacity {
            data.removeFirst(data.count - Self.capacity)
        }
    }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

/// A puck session was created, but its first turn did not start.
