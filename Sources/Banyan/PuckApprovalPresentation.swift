import BanyanCore
import Foundation

/// What a pending approval asks, read from its arguments instead of shown as
/// raw JSON. Codex sends its request params (`command`, `cwd`, `reason`,
/// `itemId`); native tools send their own call arguments.
struct PuckApprovalPresentation: Equatable {
    enum Kind: Equatable { case command, fileChange, permissions, other }

    let kind: Kind
    let command: String?
    let workingDirectory: String?
    let reason: String?
    /// A unified diff of the edits awaiting approval.
    let diff: String?
    let fileSummary: String?
    /// Anything that is not modeled above, pretty-printed when JSON.
    let details: String?

    var title: String {
        switch kind {
        case .command: "Would you like to run the following command?"
        case .fileChange: "Would you like to make the following edits?"
        case .permissions: "Would you like to grant these permissions?"
        case .other: "Would you like to approve this action?"
        }
    }

    /// `tools` are the transcript's tool rows; a Codex file-change approval
    /// names its item, whose changes carry the diff.
    init(_ pending: PuckPendingApproval, tools: [PuckToolActivity] = [], workspace: String? = nil) {
        let raw = pending.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let object = raw.data(using: .utf8)
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let tool = pending.tool.lowercased()
        reason = (object?["reason"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        if let object, let command = Self.commandText(object["command"] ?? object["cmd"]) {
            kind = .command
            self.command = command
            workingDirectory = (object["cwd"] ?? object["workdir"]) as? String
            diff = nil
            fileSummary = nil
            details = nil
            return
        }
        command = nil
        workingDirectory = nil

        if tool == "apply_patch" || tool == "patch" || tool == "edit" {
            kind = .fileChange
            let itemID = object?["itemId"] as? String ?? object?["item_id"] as? String
            let changes = itemID.flatMap { id in
                tools.first { $0.callID == id }.flatMap(\.fileChanges)
            } ?? PuckFileChanges.parse(raw)
            if let changes {
                diff = PuckFileChanges.unifiedDiff(changes)
                fileSummary = PuckFileChanges.summary(changes, relativeTo: workspace)
                details = nil
            } else if object == nil, !raw.isEmpty {
                // A native freeform patch is the patch text itself.
                diff = raw
                fileSummary = nil
                details = nil
            } else {
                diff = nil
                fileSummary = nil
                details = Self.remainingDetails(object, raw: raw)
            }
            return
        }
        diff = nil
        fileSummary = nil
        if let permissions = object?["permissions"] {
            kind = .permissions
            details = Self.pretty(permissions)
        } else {
            kind = .other
            details = Self.remainingDetails(object, raw: raw)
        }
    }

    private static func commandText(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let words = value as? [String], !words.isEmpty { return words.joined(separator: " ") }
        return nil
    }

    /// Drops Codex's routing IDs, which mean nothing to the person deciding.
    private static func remainingDetails(_ object: [String: Any]?, raw: String) -> String? {
        guard var object else { return raw.isEmpty ? nil : raw }
        for key in ["threadId", "turnId", "itemId", "reason", "approvalId"] { object.removeValue(forKey: key) }
        return object.isEmpty ? nil : pretty(object)
    }

    private static func pretty(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        else { return value as? String }
        return String(data: data, encoding: .utf8)
    }
}
