import BanyanCore
import AppKit
import Foundation
import Network

extension ControlServer {
    /// Answers with any transitions since `since`, or parks the request until one
    /// lands. Parking beats a client poll loop: nothing here runs on a schedule,
    /// and the one timer involved is a single-shot release for this request.
    @MainActor
    func waitForEvents(
        store: SessionStore,
        since: Int?,
        respond: @escaping @MainActor (Response) -> Void
    ) {
        let batch = store.sessionEvents(since: since)
        guard since != nil, batch.events.isEmpty, eventWaiters.count < Self.maxEventWaiters else {
            return respond(.ok(eventsBody(batch)))
        }

        let id = UUID()
        eventWaiters.append(EventWaiter(id: id, since: since, awayRequest: nil, respond: respond))
        queue.asyncAfter(deadline: .now() + Self.eventHoldSeconds) { [weak self] in
            Task { @MainActor in
                self?.releaseWaiter(id: id)
            }
        }
    }

    @MainActor
    func waitForAwayEvents(store: SessionStore, request: SlackBrowserRequest,
                                   respond: @escaping @MainActor (Response) -> Void) {
        do {
            let result = try store.slackAwayEvents(request)
            let currentRevision = (result["revision"] as? UInt64)
            let unchanged = request.eventEpoch == result["epoch"] as? String &&
                request.eventCursor == result["cursor"] as? Int && request.awayRevision == currentRevision &&
                request.awayActivationID == result["activationID"] as? String && result["refresh"] as? Bool == false &&
                (result["events"] as? [[String: Any]])?.isEmpty == true
            guard unchanged, eventWaiters.count < Self.maxEventWaiters else { return respond(.ok(result)) }
            let id = UUID()
            eventWaiters.append(EventWaiter(id: id, since: request.eventCursor, awayRequest: request, respond: respond))
            queue.asyncAfter(deadline: .now() + Self.eventHoldSeconds) { [weak self] in
                Task { @MainActor in self?.releaseWaiter(id: id) }
            }
        } catch CodexRemoteError.denied {
            respond(.failure(403, "remote_denied", "Slack control is disabled or principal is not allowed"))
        } catch { respond(.failure(409, "remote_unavailable", error.localizedDescription)) }
    }

    @MainActor
    var parkedAwayWaiterCount: Int { eventWaiters.filter { $0.awayRequest != nil }.count }

    @MainActor
    func response(for waiter: EventWaiter, store: SessionStore) -> Response {
        guard let request = waiter.awayRequest else { return .ok(eventsBody(store.sessionEvents(since: waiter.since))) }
        do { return .ok(try store.slackAwayEvents(request)) }
        catch CodexRemoteError.denied { return .failure(403, "remote_denied", "Slack control is disabled or principal is not allowed") }
        catch { return .failure(409, "remote_unavailable", error.localizedDescription) }
    }

    @MainActor
    func deliverParkedEvents() {
        guard !eventWaiters.isEmpty, let store else { return }
        let waiting = eventWaiters
        eventWaiters = []
        for waiter in waiting {
            waiter.respond(response(for: waiter, store: store))
        }
    }

    @MainActor
    private func releaseWaiter(id: UUID) {
        guard let index = eventWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = eventWaiters.remove(at: index)
        guard let store else { return waiter.respond(.failure(500, "store_unavailable", "session store is unavailable")) }
        waiter.respond(response(for: waiter, store: store))
    }

    private func eventsBody(_ batch: SessionEventBatch) -> [String: Any] {
        [
            "cursor": batch.cursor,
            "truncated": batch.truncated,
            "events": batch.events.map { event in
                [
                    "cursor": event.cursor,
                    "id": event.sessionID,
                    "status": event.status.rawValue,
                    "statusEmoji": event.status.emoji,
                    "previousStatus": event.previousStatus?.rawValue ?? "",
                    "at": event.at.ISO8601Format()
                ]
            }
        ]
    }
}
