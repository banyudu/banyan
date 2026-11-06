import BanyanCore
import AppKit
import Foundation
import Network

extension ControlServer {
    @MainActor
    func outputBody(id: String, store: SessionStore, reading: SessionPaneReading) -> [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "paneID": reading.paneID,
            "status": reading.status.rawValue,
            "statusEmoji": reading.status.emoji,
            // A parked session is reported, not observed: its status is whatever was
            // last seen and it carries no prompt, so say so rather than let a caller
            // read the frozen status as a live one.
            "isSuspended": reading.isSuspended,
            "isFrozen": reading.isFrozen,
            "isDeepSuspended": reading.isDeepSuspended,
            "visibleText": reading.visibleText
        ]
        if let session = store.sessions.first(where: { $0.id == id }) {
            payload["session"] = summary(session)
        }
        if let prompt = reading.prompt {
            payload["prompt"] = [
                "question": prompt.question,
                "context": prompt.context,
                "selectedIndex": prompt.selectedIndex,
                "footprint": prompt.footprint,
                "options": prompt.options.map { option in
                    [
                        "index": option.index,
                        "label": option.label,
                        "acceptsNumberKey": option.acceptsNumberKey
                    ] as [String: Any]
                }
            ] as [String: Any]
        }
        return payload
    }

    func failure(for error: Error) -> Response {
        if let error = error as? ControlError {
            return .failure(error.httpStatus, error.code, error.localizedDescription)
        }
        return .failure(400, "bad_request", error.localizedDescription)
    }

    func validateVersion(_ apiVersion: String?) throws {
        let version = apiVersion ?? ControlProtocol.version
        guard version == ControlProtocol.version else {
            throw ControlError.badRequest("unsupported apiVersion '\(version)'")
        }
    }

    func parseStatus(_ raw: String) throws -> SessionStatus {
        guard let status = SessionStatus(rawValue: raw) else {
            throw ControlError.badRequest("unknown status '\(raw)'")
        }
        return status
    }

    func parseRunMode(_ raw: String) throws -> CommandRunMode {
        guard let run = CommandRunMode(rawValue: raw) else {
            throw ControlError.badRequest(
                "unknown run '\(raw)'; allowed: \(CommandRunMode.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        return run
    }

    func suggestionBody(_ suggestion: InboundSuggestion) -> [String: Any] {
        [
            "key": suggestion.key,
            "title": suggestion.title,
            "detail": suggestion.detail ?? "",
            "target": suggestion.target ?? "",
            "command": suggestion.command,
            "cwd": suggestion.cwd ?? "",
            "run": suggestion.run.rawValue,
            "receivedAt": suggestion.receivedAt.ISO8601Format(),
            "expiresAt": suggestion.expiresAt.ISO8601Format()
        ]
    }

    func parseTone(_ raw: String) throws -> SessionTone {
        guard let tone = SessionTone(rawValue: raw) else {
            throw ControlError.badRequest("unknown tone '\(raw)'")
        }
        return tone
    }

    @MainActor
    func windowState() -> [String: Any] {
        let window = NSApp.windows.first { $0.isVisible } ?? NSApp.mainWindow
        var state: [String: Any] = [
            "title": window?.title ?? "",
            "titleVisibility": window?.titleVisibility == .hidden ? "hidden" : "visible"
        ]
        state["selectedSessionID"] = store?.selectedSessionID ?? ""
        if let context = store?.selectedContextInfo {
            let selectedContext: [String: String] = [
                "sessionID": context.sessionID,
                "linearIssueID": context.linearIssueID ?? "",
                "linearIssueTitle": context.linearIssueTitle ?? "",
                "linearIssueURL": context.linearIssueURL ?? "",
                "pullRequestNumber": context.pullRequestNumber.map(String.init) ?? "",
                "pullRequestTitle": context.pullRequestTitle ?? "",
                "pullRequestURL": context.pullRequestURL ?? ""
            ]
            state["selectedContext"] = selectedContext
        }
        if let window {
            state["windowWidth"] = window.frame.width
            let actionFrames = [
                viewFrame(window: window, identifier: AccessibilityID.toolbarPullRequestLink),
                viewFrame(window: window, identifier: AccessibilityID.toolbarAddSession),
                viewFrame(window: window, identifier: AccessibilityID.toolbarPreferences)
            ].compactMap(\.self)
            if let contextFrame = viewFrame(window: window, identifier: AccessibilityID.toolbarContext) {
                state["toolbarContextFound"] = true
                state["toolbarContextMinX"] = contextFrame.minX
                state["toolbarContextMaxX"] = contextFrame.maxX
                state["toolbarContextWidth"] = contextFrame.width
            } else {
                state["toolbarContextFound"] = false
            }
            if let sessionTitleFrame = viewFrame(window: window, identifier: AccessibilityID.toolbarSessionTitle) {
                state["toolbarSessionTitleFound"] = true
                state["toolbarSessionTitleMinX"] = sessionTitleFrame.minX
                state["toolbarSessionTitleMaxX"] = sessionTitleFrame.maxX
                state["toolbarSessionTitleWidth"] = sessionTitleFrame.width
            } else {
                state["toolbarSessionTitleFound"] = false
            }
            if !actionFrames.isEmpty {
                let actionsFrame = actionFrames.dropFirst().reduce(actionFrames[0]) { $0.union($1) }
                state["toolbarActionsFound"] = true
                state["toolbarActionsMinX"] = actionsFrame.minX
                state["toolbarActionsMaxX"] = actionsFrame.maxX
                state["toolbarActionsWidth"] = actionsFrame.width
            } else {
                state["toolbarActionsFound"] = false
            }
        }
        return state
    }

    @MainActor
    private func viewFrame(window: NSWindow, identifier: String) -> NSRect? {
        let roots = [window.contentView, window.contentView?.superview].compactMap(\.self)
        for root in roots {
            if let view = firstSubview(in: root, identifier: identifier) {
                return view.convert(view.bounds, to: nil)
            }
        }
        return nil
    }

    private func firstSubview(in view: NSView, identifier: String) -> NSView? {
        if view.identifier?.rawValue == identifier || view.accessibilityIdentifier() == identifier {
            return view
        }
        for subview in view.subviews {
            if let match = firstSubview(in: subview, identifier: identifier) {
                return match
            }
        }
        return nil
    }

    @MainActor
    func admissionSummary(_ store: SessionStore) -> [String: Any] {
        ["limit": store.maximumConcurrentAgents,
         "running": store.agentAdmission.running.sorted(),
         "queued": store.agentAdmission.queuedIDs]
    }

    @MainActor
    func summary(_ session: BanyanSession) -> [String: Any] {
        var summary: [String: Any] = [
            "id": session.id,
            "backend": session.backendKind.rawValue,
            "tmuxSessionName": session.persistedTmuxSessionName ?? "",
            "title": session.title,
            "titleURL": session.titleURL ?? "",
            "displayTitle": session.displayTitle,
            "reportedTitle": session.reportedTitle ?? "",
            "generatedTitle": session.generatedTitle ?? "",
            "contextualTitle": session.contextualTitle ?? "",
            "agentProvider": session.agentProvider?.rawValue ?? "",
            "cwd": session.cwd,
            "command": session.command,
            "status": session.status.rawValue,
            "statusEmoji": session.status.emoji,
            "backgroundTerminalCount": session.backgroundTerminalCount,
            "tone": session.tone.rawValue,
            "parent": session.parentSessionID ?? "",
            "isRestored": session.isRestored,
            "needsRecovery": session.needsRecovery,
            "agentSessionID": session.agentSessionID ?? "",
            "isProcessStarted": session.isProcessStarted,
            "isSuspended": session.isSuspended,
            "isFrozen": session.isFrozen,
            "isDeepSuspended": session.isDeepSuspended,
            "isDeepResuming": session.isDeepResuming,
            "isDeepTerminating": session.isDeepTerminating,
            "deepRecoveryIsUncertain": (session as? TerminalSession)?.deepRecoveryIsUncertain ?? false,
            "agentQueuePosition": session.agentQueuePosition as Any? ?? NSNull(),
            "agentLaunchCancelled": session.agentLaunchQueue?.cancelled ?? false,
            "usesAgentSlot": store?.agentAdmission.running.contains(session.id) ?? false,
            "projectGroupID": session.projectGroupID,
            "projectGroupTitle": session.projectGroupTitle,
            "displayContextDegraded": session.displayContextDegraded,
            // Explicit history queries can include many rows. Two ICU-backed
            // formatters per row dominated CPU samples in large workspaces.
            "createdAt": session.createdAt.ISO8601Format(),
            "updatedAt": session.updatedAt.ISO8601Format()
        ]

        if let workflow = session.workflow, let data = try? JSONEncoder().encode(workflow),
           let object = try? JSONSerialization.jsonObject(with: data) {
            summary["workflow"] = object
        }
        if let error = session.workflowRecoveryError { summary["workflowRecoveryError"] = error }
        if let error = session.coordinationRecoveryError { summary["coordinationRecoveryError"] = error }
        if let state = store?.codexTUIOwnership[session.id], state.threadID == session.agentSessionID {
            summary["codexTUIOwnership"] = ["threadID": state.threadID, "state": state.state.rawValue, "message": state.state.message,
                "observedAt": state.observedAt.ISO8601Format()]
        }
        if let binding = session.codexBinding,
           let data = try? JSONEncoder().encode(binding),
           let provenance = try? JSONSerialization.jsonObject(with: data) {
            summary["codex"] = provenance
        }
        if let puck = session as? PuckSession {
            summary["puck"] = [
                "provider": puck.binding.provider,
                "model": puck.binding.model ?? "",
                "account": puck.binding.account ?? "",
                "position": puck.position ?? ""
            ]
        }
        return summary
    }
}
