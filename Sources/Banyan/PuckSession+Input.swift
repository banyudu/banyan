import AppKit
import BanyanCore
import Foundation
import UniformTypeIdentifiers

/// An image attached to the composer. Pasted images are staged by Banyan;
/// puckd copies every attachment into its own store when it accepts the
/// turn, so a staged copy is discarded once the daemon has it.
struct PuckDraftImage: Identifiable, Equatable, Sendable {
    let id = UUID()
    let path: String
    /// Banyan wrote this file (a paste); a dropped file belongs to the user.
    let isStaged: Bool

    var name: String { (path as NSString).lastPathComponent }

    /// puckd's own limit; checked here so an oversized paste fails at once.
    static let maxBytes = 20 * 1_048_576

    static var stagingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("BanyanPuckAttachments", isDirectory: true)
    }

    static func stage(pngData: Data) throws -> PuckDraftImage {
        guard pngData.count <= maxBytes else { throw PuckImageAttachmentError.tooLarge }
        let directory = stagingDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("pasted-\(UUID().uuidString.lowercased()).png")
        try pngData.write(to: url, options: .atomic)
        return PuckDraftImage(path: url.path, isStaged: true)
    }

    static func file(_ url: URL) throws -> PuckDraftImage {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentTypeKey])
        guard values.isRegularFile == true, values.contentType?.conforms(to: .image) == true else {
            throw PuckImageAttachmentError.notAnImage(url.lastPathComponent)
        }
        guard (values.fileSize ?? 0) <= maxBytes else { throw PuckImageAttachmentError.tooLarge }
        return PuckDraftImage(path: url.path, isStaged: false)
    }

    static func isImageFile(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType?.conforms(to: .image) == true
    }

    static func discardStaged(_ images: [PuckDraftImage]) {
        for image in images where image.isStaged {
            try? FileManager.default.removeItem(atPath: image.path)
        }
    }
}

enum PuckImageAttachmentError: LocalizedError {
    case tooLarge
    case notAnImage(String)
    case unsupported

    var errorDescription: String? {
        switch self {
        case .tooLarge: "Images must be 20 MB or smaller."
        case .notAnImage(let name): "\(name) is not an image."
        case .unsupported: "This session can't take images. Image input needs an updated puckd and a Codex-engine session."
        }
    }
}

struct PuckQueuedPrompt: Identifiable, Equatable, Sendable {
    let id = UUID()
    let text: String
    let images: [PuckDraftImage]
}

extension PuckSession {
    /// Whether `session.turn` takes images for this session. False until the
    /// daemon has reported its capabilities.
    var acceptsImages: Bool {
        daemonCapabilities?.acceptsImages(engine: engine) ?? false
    }

    /// A new message waits in the queue rather than starting a turn now.
    var isBusyForNewTurn: Bool {
        turnUnavailableReason != nil || admissionTurnInFlight || queueDispatchInFlight
            || cancelInFlight || compactInFlight || !queuedPrompts.isEmpty
    }

    func refreshDaemonCapabilities() {
        let daemon = self.daemon
        Task { [weak self] in
            let capabilities = try? await PuckBackgroundIO.run { try daemon.capabilities() }
            self?.daemonCapabilities = capabilities
        }
    }

    // MARK: Attachments

    /// The attachments the draft's text names, by placeholder number. An
    /// attachment whose placeholder was deleted stays in `draftImages`, so
    /// undo can bring it back, but is not shown or sent.
    var attachedDraftImages: [(number: Int, image: PuckDraftImage)] {
        PuckImagePlaceholders.referencedNumbers(in: draft, imageCount: draftImages.count)
            .map { ($0, draftImages[$0 - 1]) }
    }

    /// Adds an image and returns the placeholder that names it. The caller
    /// puts the placeholder in the draft: the field inserts it at the caret.
    @discardableResult
    func attachImage(pngData: Data) -> String? {
        attach { try PuckDraftImage.stage(pngData: pngData) }
    }

    @discardableResult
    func attachImageFile(_ url: URL) -> String? {
        attach { try PuckDraftImage.file(url) }
    }

    /// Images chosen outside the field are named at the end of the draft.
    func appendImageFiles(_ urls: [URL]) {
        let labels = urls.compactMap(attachImageFile)
        guard !labels.isEmpty else { return }
        let end = NSRange(location: (draft as NSString).length, length: 0)
        draft += PuckImagePlaceholders.insertion(of: labels, at: end, in: draft)
    }

    private func attach(_ make: () throws -> PuckDraftImage) -> String? {
        guard acceptsImages else {
            daemonError = PuckImageAttachmentError.unsupported.localizedDescription
            return nil
        }
        do {
            draftImages.append(try make())
            daemonError = nil
            return PuckImagePlaceholders.label(draftImages.count)
        } catch {
            daemonError = error.localizedDescription
            return nil
        }
    }

    /// Removing an image deletes its placeholders from the draft.
    func removeDraftImage(_ image: PuckDraftImage) {
        guard let index = draftImages.firstIndex(where: { $0.id == image.id }) else { return }
        draft = PuckImagePlaceholders.removing(index + 1, from: draft)
    }

    /// Replaces the whole draft, discarding staged images it no longer holds.
    func replaceDraft(text: String, images: [PuckDraftImage]) {
        let kept = Set(images.map(\.id))
        PuckDraftImage.discardStaged(draftImages.filter { !kept.contains($0.id) })
        draft = text
        draftImages = images
    }

    // MARK: Queue

    func removeQueuedPrompt(_ prompt: PuckQueuedPrompt) {
        queuedPrompts.removeAll { $0.id == prompt.id }
        PuckDraftImage.discardStaged(prompt.images)
    }

    /// Moves a queued message back into the composer for editing.
    func editQueuedPrompt(_ prompt: PuckQueuedPrompt) {
        guard queuedPrompts.contains(where: { $0.id == prompt.id }) else { return }
        queuedPrompts.removeAll { $0.id == prompt.id }
        let merged = PuckImagePlaceholders.merged([(prompt.text, prompt.images), (draft, draftImages)])
        draft = merged.text
        draftImages = merged.images
    }

    /// Sends the next queued message once the daemon would take a turn. A
    /// user-requested stop returns the queue to the composer instead.
    func dispatchQueuedPromptIfReady() {
        guard !queuedPrompts.isEmpty, status != .closed, !isSuspended,
              turnUnavailableReason == nil, !turnPhase.isTurnActive,
              !admissionTurnInFlight, !queueDispatchInFlight, !cancelInFlight, !compactInFlight else { return }
        if restoreQueueOnStop {
            restoreQueueOnStop = false
            let queued = queuedPrompts
            queuedPrompts = []
            let merged = PuckImagePlaceholders.merged(queued.map { ($0.text, $0.images) } + [(draft, draftImages)])
            draft = merged.text
            draftImages = merged.images
            return
        }
        let next = queuedPrompts.removeFirst()
        queueDispatchInFlight = true
        dispatch(next, restoreToDraftOnRejection: false)
    }

    /// Tracks the elapsed-time origin of the active turn and finishes a
    /// compaction once its turn settles.
    func noteTurnActivity() {
        if turnPhase.isTurnActive {
            if turnStartedAt == nil { turnStartedAt = Date() }
        } else {
            turnStartedAt = nil
            if compactAccepted {
                compactAccepted = false
                compactInFlight = false
                infoNotice = "Conversation compacted."
            }
        }
    }

    // MARK: Commands

    /// Summarizes the conversation in puckd to free context.
    func compact() {
        guard !turnPhase.isTurnActive, !compactInFlight, !admissionTurnInFlight else {
            daemonError = "Wait for the current turn to finish before compacting."
            return
        }
        compactInFlight = true
        daemonError = nil
        infoNotice = "Compacting the conversation…"
        let daemon = self.daemon
        let id = self.id
        Task { [weak self] in
            do {
                try await PuckBackgroundIO.run { try daemon.compact(id) }
                guard let self else { return }
                self.compactAccepted = true
                if self.turnStartedAt == nil { self.turnStartedAt = Date() }
                let summary = try await PuckBackgroundIO.run { try daemon.get(id) }
                self.apply(summary: summary)
            } catch {
                guard let self else { return }
                self.compactInFlight = false
                self.compactAccepted = false
                self.infoNotice = nil
                self.daemonError = error.localizedDescription
                self.dispatchQueuedPromptIfReady()
            }
        }
    }

    /// Denies the pending call and tells the agent what to do instead. The
    /// native engine shows the reason to the model with the denial. Codex
    /// cannot take a reason, so the turn stops and the feedback becomes the
    /// next message, as Codex's own "tell Codex what to do differently" does.
    func denyWithFeedback(_ feedback: String) {
        let text = feedback.trimmingCharacters(in: .whitespacesAndNewlines)
        let stopsTurn = engine == "codex"
        decide("deny", reason: text.isEmpty ? nil : text) { [weak self] in
            guard let self, stopsTurn else { return }
            if !text.isEmpty {
                self.queuedPrompts.insert(PuckQueuedPrompt(text: text, images: []), at: 0)
            }
            self.cancel(restoringQueue: false)
        }
    }

    /// `/status`: who runs the session and what it has used.
    func statusSummary() -> String {
        var parts = ["Puck · \(engine) engine", binding.provider]
        if let model = binding.model { parts.append(model) }
        if let account = binding.account { parts.append("account \(account)") }
        var lines = [parts.joined(separator: " · "), "Workspace: \(cwd)", "Session: \(id)"]
        if let usage = timeline.usage?.total {
            var tokens = "Tokens: \(usage.inputTokens.formatted()) in · \(usage.outputTokens.formatted()) out"
            if usage.cachedInputTokens > 0 { tokens += " · \(usage.cachedInputTokens.formatted()) cached" }
            lines.append(tokens)
        }
        lines.append("Images: \(acceptsImages ? "supported" : "not supported")")
        return lines.joined(separator: "\n")
    }

    /// `/copy`: the newest assistant message.
    @discardableResult
    func copyLatestResponse() -> Bool {
        guard let text = timeline.items.reversed().first(where: { $0.role == .assistant })?.text,
              !text.isEmpty else {
            infoNotice = "There is no response to copy yet."
            return false
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        infoNotice = "Copied the latest response."
        return true
    }
}
