"""Transport-independent connector. Never launches Codex or injects terminal input."""
import asyncio
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import time
import uuid


class Unavailable(Exception):
    """Safe, content-free error for local status reporting."""


class Denied(Unavailable):
    """An authoritative authorization refusal, distinct from transport loss."""


class StaleAttachment(Unavailable):
    """Authoritative snapshot refused an obsolete attachment binding."""


class RateLimited(Unavailable):
    def __init__(self, retry_after):
        self.retry_after = max(0.01, float(retry_after))


class Journal:
    MAX_BYTES = 16 * 1024 * 1024

    def __init__(self, path):
        self.path = Path(path)
        self.failed = False
        if self.path.exists():
            if self.path.stat().st_size > self.MAX_BYTES:
                raise Unavailable("Connector journal too large")
            self.data = json.loads(self.path.read_text())
            if self.data.get("version") != 1:
                raise Unavailable("Unsupported connector journal")
        else:
            self.data = {"version": 1, "incoming": {}, "posts": {}, "controls": {}, "modals": {}, "cursors": {}}
        # A process crash does not prove that an HTTP or Slack submission failed.
        for group in ("incoming", "posts"):
            for value in self.data[group].values():
                if value.get("status") == "sending":
                    value["status"] = "uncertain"

    def commit(self, mutation):
        if self.failed:
            raise Unavailable("Connector storage unavailable")
        next_data = copy.deepcopy(self.data)
        mutation(next_data)
        encoded = json.dumps(next_data, separators=(",", ":")).encode()
        if len(encoded) > self.MAX_BYTES:
            raise Unavailable("Connector journal full; preserve deduplication evidence")
        temporary = None
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            descriptor, temporary = tempfile.mkstemp(dir=self.path.parent)
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "wb") as output:
                output.write(encoded)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temporary, self.path)
            self.data = next_data
        except OSError:
            self.failed = True
            raise Unavailable("Connector journal write failed") from None
        finally:
            if temporary and os.path.exists(temporary):
                os.unlink(temporary)


def stable_id(*parts):
    return hashlib.sha256(json.dumps(parts, sort_keys=True).encode()).hexdigest()


def plain(text):
    return {"type": "plain_text", "text": str(text)[:2900] or " "}


def section(text):
    return {"type": "section", "text": plain(text)}


class Connector:
    def __init__(self, api, slack, state_path, allowed, bot_user, post_interval=1):
        self.api, self.slack = api, slack
        self.journal = Journal(state_path)
        self.allowed = {tuple(p.get(k, "") for k in ("workspace", "channel", "user")) for p in allowed}
        self.bot_user = bot_user
        self.lock = asyncio.Lock()  # SDK callbacks may overlap; claim + write is serialized.
        self.enabled = True
        self.online = False
        self.denied_principals = set()
        self.cancelled_attachments = set()
        self.authorization_denied = False
        self.socket_connected = True
        self.socket_synchronized = True
        self.connection_generation = 0
        self.needs_refresh = False
        self.sessions = {}
        self.generation = 0
        self.last_progress = {}
        self.last_post = {}
        self.post_interval = post_interval

    def permitted(self, principal):
        key = tuple(principal.get(k, "") for k in ("workspace", "channel", "user"))
        return self.enabled and self.socket_connected and not self.journal.failed and all(key) and key in self.allowed

    async def call_api(self, body):
        try:
            return await self.api.call(body)
        except Denied:
            principal = body.get("principal", {})
            self.denied_principals.add(tuple(principal.get(k, "") for k in ("workspace", "channel", "user")))
            self.authorization_denied = True
            self.online = False
            raise

    async def check(self, principal, synchronizing=False, binding=None):
        if not self.permitted(principal) or (not synchronizing and not self.socket_synchronized):
            raise Unavailable("Control denied")
        # Fence transport sends against the authoritative Mac disable/allowlist.
        await self.call_api({"action": "list", "principal": principal})
        if not self.permitted(principal) or (not synchronizing and not self.socket_synchronized):
            raise Unavailable("Control disabled")
        if binding:
            try:
                session = await self.call_api({"action": "snapshot", "principal": principal, **binding})
                if self.binding(session) != binding:
                    raise StaleAttachment("Attachment changed")
            except StaleAttachment:
                self.cancel_attachment(binding)
                raise
            if not self.permitted(principal) or (not synchronizing and not self.socket_synchronized):
                raise Unavailable("Control disabled")
        self.denied_principals.discard(tuple(principal[k] for k in ("workspace", "channel", "user")))
        self.authorization_denied = bool(self.denied_principals)

    def cancel_attachment(self, binding):
        aid = binding["attachmentID"]
        self.cancelled_attachments.add(aid)
        def cancel(data):
            for post in data["posts"].values():
                if post["status"] == "retryable" and (post.get("binding") or {}).get("attachmentID") == aid:
                    post["status"] = "cancelled"
                    post.pop("retry", None)
        self.journal.commit(cancel)

    def binding(self, session):
        a = session["attachment"]
        return {"sessionID": session["sessionID"], "threadID": session["threadID"],
                "attachmentID": a["id"], "slackThread": a["slackThread"]}

    def control(self, body, principal):
        token = stable_id(body, principal["workspace"], principal["channel"])
        if token in self.journal.data["controls"]:
            return token
        descriptor = {"body": body, "workspace": principal["workspace"], "channel": principal["channel"]}
        self.journal.commit(lambda d: d["controls"].__setitem__(token, descriptor))
        return token

    def button(self, label, body, principal):
        return {"type": "button", "action_id": "banyan_control", "text": plain(label),
                "value": self.control(body, principal)}

    async def post_once(self, key, principal, root, text, blocks=None, binding=None):
        await self.check(principal, binding=binding)
        old = self.journal.data["posts"].get(key)
        if old and old["status"] != "retryable":
            return old.get("ts")  # Unknown deliveries are NEVER posted again.
        if old and old.get("retryAt", 0) > time.time() + 30:
            return None  # Durable known-not-sent; the event loop revisits it.
        for attempt in range(3):
            old = self.journal.data["posts"].get(key, {})
            delay = max(old.get("retryAt", 0) - time.time(),
                self.last_post.get(principal["channel"], 0) + self.post_interval - time.monotonic(), 0)
            if delay > 0:
                await asyncio.sleep(delay)  # Never block an SDK worker or disable.
            await self.check(principal, binding=binding)  # Fresh policy AND attachment fence after wait.
            self.journal.commit(lambda d: d["posts"].__setitem__(key, {
                "status": "sending", "channel": principal["channel"], "root": root, "binding": binding}))
            try:
                self.last_post[principal["channel"]] = time.monotonic()
                result = await self.slack.call("chat.postMessage", channel=principal["channel"], thread_ts=root,
                    text=str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")[:3000],
                    blocks=blocks or [section(text)], parse="none", unfurl_links=False, unfurl_media=False,
                    metadata={"event_type": "banyan_remote", "event_payload": {"delivery_id": key}})
                ts = result["ts"]
                self.journal.commit(lambda d: d["posts"][key].update(status="sent", ts=ts))
                return ts
            except RateLimited as error:
                self.journal.commit(lambda d: d["posts"][key].update(status="retryable", retryAt=time.time() + error.retry_after,
                    retry={"principal": principal, "root": root, "text": text, "blocks": blocks, "binding": binding}))
                if error.retry_after > 30:
                    return None
            except (Exception, asyncio.CancelledError) as error:
                self.journal.commit(lambda d: d["posts"][key].update(status="uncertain"))
                self.online = False
                if isinstance(error, asyncio.CancelledError):
                    raise
                raise Unavailable("Slack delivery outcome unknown; inspect connector status and reconcile locally") from None
        return None

    async def mutate(self, key, body):
        await self.check(body["principal"])
        old = self.journal.data["incoming"].get(key)
        if old:
            if old["body"] != body:
                raise Unavailable("Duplicate identity changed payload")
            # Resolve a lost HTTP result via receipt; NEVER send it again.
            if old["status"] == "uncertain" and body["action"] in ("queue", "steer", "stop", "respond"):
                receipt = await self.call_api({**body, "action": "receipt"})
                if receipt["status"] != "absent":
                    self.journal.commit(lambda d: d["incoming"][key].update(status="done", result=receipt))
                    return receipt
            return old.get("result", {"status": old["status"]})
        self.journal.commit(lambda d: d["incoming"].__setitem__(key, {"status": "sending", "body": body}))
        try:
            result = await self.call_api(body)
            self.journal.commit(lambda d: d["incoming"][key].update(status="done", result=result))
            return result
        except Exception:
            self.journal.commit(lambda d: d["incoming"][key].update(status="uncertain"))
            self.online = False
            raise

    async def envelope(self, envelope, acknowledge):
        # Always ACK first, including denied, malformed, duplicate deliveries.
        await acknowledge(envelope.get("envelope_id"))
        async with self.lock:
            if not self.enabled or not self.socket_synchronized:
                return
            try:
                await self._handle(envelope)
            except Exception:
                self.online = False  # No credentials, payloads or model output in logs.

    async def _handle(self, envelope):
        payload = envelope.get("payload", {})
        if envelope.get("type") == "events_api":
            event = payload.get("event", {})
            if event.get("type") not in ("app_mention", "message") or event.get("bot_id") or event.get("subtype"):
                return
            principal = {"workspace": payload.get("team_id", ""), "channel": event.get("channel", ""), "user": event.get("user", "")}
            if not self.permitted(principal):
                return
            await self.check(principal)
            # Message ts is stable across message/app_mention and Socket retries.
            key = stable_id(principal["workspace"], principal["channel"], event.get("ts"))
            text = event.get("text", "")
            mention = f"<@{self.bot_user}>"
            root = event.get("thread_ts") or event.get("ts")
            if text.startswith(mention):
                command = text[len(mention):].strip()
                if command == "list":
                    result = await self.call_api({"action": "list", "principal": principal})
                    rows = [f"{s['sessionID']} · {s['title']} · {s['project']} · {s['state']}" +
                            (" · input needed" if s["needsAttention"] else "") for s in result["sessions"]]
                    await self.post_once(key, principal, root, "Native Codex sessions\n" + "\n".join(rows)[:2500])
                    return
                if command.startswith("attach "):
                    listing = await self.call_api({"action": "list", "principal": principal})
                    session = next((s for s in listing["sessions"] if s["sessionID"] == command[7:].strip()), None)
                    if not session:
                        return
                    # User message is the explicit thread root. No uncertain bot
                    # post can accidentally create a replacement attachment.
                    result = await self.mutate(key, {"action": "attach", "principal": principal,
                        "sessionID": session["sessionID"], "threadID": session["threadID"], "slackThread": root})
                    if "attachment" in result:
                        self.sessions[result["attachment"]["id"]] = result
                        await self.render(result, principal, notify="attached")
                    return
            session = next((s for s in self.sessions.values() if s["attachment"]["workspace"] == principal["workspace"]
                and s["attachment"]["channel"] == principal["channel"] and s["attachment"]["slackThread"] == root), None)
            if not session or event.get("ts") == root or not text.strip():
                return
            session = await self.call_api({"action": "snapshot", "principal": principal, **self.binding(session)})
            if text.strip() == f"<@{self.bot_user}> reconcile":
                session = await self.call_api({"action": "reconcile", "principal": principal, **self.binding(session)})
                await self.render(session, principal)
                return
            body = {"action": "queue", "principal": principal, **self.binding(session), "operationID": key, "text": text}
            result = await self.mutate(key, body)
            blocks = [section(f"{session['title']} · {session['project']}\nReply {result.get('status', 'uncertain')}")]
            if result.get("status") == "queued" and session.get("turnID") and not session.get("needsAttention"):
                blocks.append({"type": "actions", "elements": [self.button("Steer current turn", {
                    **self.binding(session), "action": "steer", "turnID": session["turnID"],
                    "text": text, "queuedOperationID": key}, principal)]})
            await self.post_once("receipt-" + key, principal, root, f"{session['title']}: reply {result.get('status')}", blocks, binding=self.binding(session))
        elif envelope.get("type") == "interactive":
            await self.interaction(payload)

    async def interaction(self, payload):
        workspace = payload.get("team", {}).get("id", "")
        user = payload.get("user", {}).get("id", "")
        if payload.get("type") == "view_submission":
            token = payload.get("view", {}).get("private_metadata", "")
            modal = self.journal.data["modals"].get(token)
            if not modal or modal["principal"]["workspace"] != workspace or modal["principal"]["user"] != user:
                return
            principal = modal["principal"]  # Channel comes from trusted opening action, never button JSON.
            await self.check(principal)
            body = copy.deepcopy(modal["body"])
            values = payload["view"].get("state", {}).get("values", {})
            body["answers"] = {qid: value.get("answer", {}).get("value") or
                value.get("answer", {}).get("selected_option", {}).get("value", "") for qid, value in values.items()}
            key = stable_id(workspace, user, payload["view"]["id"], token)
        else:
            channel = payload.get("channel", {}).get("id", "")
            principal = {"workspace": workspace, "channel": channel, "user": user}
            if not self.permitted(principal):
                return
            actions = payload.get("actions", [])
            if len(actions) != 1:
                return
            action = actions[0]
            descriptor = self.journal.data["controls"].get(action.get("value"))
            if not descriptor or descriptor["workspace"] != workspace or descriptor["channel"] != channel:
                return
            await self.check(principal)
            body = copy.deepcopy(descriptor["body"])
            key = stable_id(workspace, channel, user, payload.get("container", {}).get("message_ts"),
                            action.get("action_id"), action.get("action_ts"))
            if body["action"] == "question":
                session = await self.call_api({"action": "snapshot", "principal": principal, **self.binding_from_body(body)})
                request = next((r for r in session["requests"] if r["id"] == body["requestID"] and r["turnID"] == body["turnID"]), None)
                if not request or not request.get("answerable", True):
                    await self.render(session, principal)
                    return
                await self.open_question(request, body, principal, payload.get("trigger_id"))
                return
        body.update(principal=principal, operationID=key)
        try:
            await self.mutate(key, body)
        finally:
            # Server validates stale request/turn IDs; refresh removes old controls.
            try:
                session = await self.call_api({"action": "snapshot", "principal": principal, **self.binding_from_body(body)})
                await self.render(session, principal)
            except Exception:
                await self.offline_message(body.get("attachmentID"), principal)

    @staticmethod
    def binding_from_body(body):
        return {k: body[k] for k in ("sessionID", "threadID", "attachmentID", "slackThread")}

    async def open_question(self, request, body, principal, trigger):
        if not trigger or any(q["secret"] for q in request["questions"]) or len(request["questions"]) > 15:
            return
        if any(len(q["id"]) > 255 or len(q["question"]) > 2000 or len(q["options"]) > 100
               or any(len(o["label"]) > 150 for o in q["options"]) for q in request["questions"]):
            return
        blocks = []
        for question in request["questions"]:
            options = question["options"]
            if options and not question["allowsOther"]:
                element = {"type": "static_select", "action_id": "answer", "options": [
                    {"text": plain(o["label"][:75]), "value": o["label"]} for o in options[:100]]}
            else:
                element = {"type": "plain_text_input", "action_id": "answer", "multiline": True, "max_length": 4000}
            blocks.append({"type": "input", "block_id": question["id"], "label": plain(question["question"][:2000]), "element": element})
        token = str(uuid.uuid4())
        reply = {**body, "action": "respond"}
        self.journal.commit(lambda d: d["modals"].__setitem__(token, {"body": reply, "principal": principal}))
        await self.check(principal, binding=self.binding_from_body(body))
        await self.slack.call("views.open", trigger_id=trigger, view={"type": "modal", "callback_id": "banyan_answer",
            "private_metadata": token, "title": plain("Answer Codex"), "submit": plain("Send"), "blocks": blocks})

    async def render(self, session, principal, notify=None):
        binding = self.binding(session)
        await self.check(principal, binding=binding)
        attachment = session["attachment"]
        self.sessions[attachment["id"]] = session
        heading = f"{session['title']} · {session['project']}"
        state = ("Input needed" if session["needsAttention"] else session.get("lastTurnStatus") or session["state"])
        if not session["available"]:
            state = "Unavailable — reconnect Banyan on the Mac"
        blocks = [section(heading + "\n" + state)]
        context = "\n".join(f"{i['type']}: {i['text']}" for i in session.get("context", [])[-5:])
        if context:
            blocks.append(section(context[-2800:]))
        receipts = session.get("receipts", [])
        pending = [r for r in receipts if r["status"] in ("queued", "submitting", "uncertain")]
        if pending:
            blocks.append(section("\n".join(f"{r['operationID']}: {r['status']}" for r in pending)))
        binding = self.binding(session)
        if session["available"]:
            for request in session.get("requests", [])[:10]:
                if not request.get("answerable", True):
                    blocks.append(section("Request answered; waiting for Codex confirmation"))
                    continue
                blocks.append(section(request["title"] + "\n" + request.get("detail", "")))
                controls = []
                request_body = {**binding, "turnID": request["turnID"], "requestID": request["id"]}
                for decision in request["decisions"]:
                    controls.append(self.button("Approve Once" if decision == "accept" else "Deny",
                        {**request_body, "action": "respond", "decision": decision}, principal))
                if request["questions"] and not any(q["secret"] for q in request["questions"]):
                    for q in request["questions"]:
                        blocks.append(section(q["question"]))
                    controls.append(self.button("Answer questions", {**request_body, "action": "question"}, principal))
                if controls:
                    blocks.append({"type": "actions", "elements": controls})
            controls = [self.button("Detach", {**binding, "action": "detach"}, principal)]
            if session.get("turnID"):
                controls.insert(0, self.button("Stop turn", {**binding, "action": "stop", "turnID": session["turnID"]}, principal))
            blocks.append({"type": "actions", "elements": controls})
        key = "status-" + attachment["id"]
        ts = await self.post_once(key, principal, attachment["slackThread"], heading + ": " + state, blocks[:50], binding=binding)
        if ts:
            await self.check(principal, binding=binding)
            await self.slack.call("chat.update", channel=principal["channel"], ts=ts,
                text=heading.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;") + ": " + state, blocks=blocks[:50], parse="none")
        if notify:
            # Lifecycle notification is separate from the replaceable status panel.
            await self.post_once("notice-" + stable_id(attachment["id"], notify), principal,
                attachment["slackThread"], heading + ": " + state, binding=binding)

    async def offline_message(self, attachment_id, principal):
        self.online = False
        post = self.journal.data["posts"].get("status-" + str(attachment_id), {})
        if attachment_id in self.cancelled_attachments or not post.get("ts") or not self.enabled or tuple(principal.get(k, "") for k in ("workspace", "channel", "user")) in self.denied_principals or self.journal.failed:
            return
        # An API disconnect cannot authorize fresh content/actions. Replace the
        # already published panel with a content-free offline notice, no buttons.
        await self.slack.call("chat.update", channel=principal["channel"], ts=post["ts"],
            text="Banyan unavailable. Keep the Mac and Banyan running; reconnecting.",
            blocks=[section("Banyan unavailable. Controls paused until authoritative state refresh.")], parse="none")

    def socket_closed(self):
        self.connection_generation += 1
        self.socket_connected = False
        self.socket_synchronized = False
        self.needs_refresh = True
        self.online = False

    def socket_hello(self):
        self.connection_generation += 1
        self.socket_connected = True
        self.socket_synchronized = False
        self.needs_refresh = True

    async def refresh(self, principal, first=False):
        async with self.lock:
            if not self.permitted(principal):
                return
            generation = self.connection_generation
            first = first or self.needs_refresh
            cursor_key = stable_id(principal["workspace"], principal["channel"])
            saved = self.journal.data["cursors"].get(cursor_key, {})
        # Long poll must not hold the callback mutex.
        response = await self.call_api({"action": "sync" if first else "events", "principal": principal, **saved})
        async with self.lock:
            if not self.permitted(principal) or generation != self.connection_generation:
                return
            await self.check(principal, synchronizing=True)
            if generation != self.connection_generation:
                return
            self.socket_synchronized = True
            self.needs_refresh = False
            self.online = True
            current = {s["attachment"]["id"]: s for s in response["sessions"] if s.get("attachment")}
            removed = [s for aid, s in self.sessions.items() if s["attachment"]["workspace"] == principal["workspace"]
                and s["attachment"]["channel"] == principal["channel"] and aid not in current]
            for session in removed:
                self.cancel_attachment(self.binding(session))
                self.sessions.pop(session["attachment"]["id"], None)
            obsolete = {post["binding"]["attachmentID"]: post["binding"]
                for post in self.journal.data["posts"].values()
                if post["status"] == "retryable" and post.get("binding")
                and post.get("retry", {}).get("principal") == principal
                and post["binding"]["attachmentID"] not in current}
            for binding in obsolete.values():
                self.cancel_attachment(binding)
            for session in current.values():
                relevant = [e for e in response["events"] if e["attachment"]["id"] == session["attachment"]["id"]]
                # Progress replaces one panel at most every 2 seconds. Attention
                # and completion bypass coalescing, deltas never reach this API.
                urgent = [e for e in relevant if e["kind"] in ("attention", "turn/completed", "error")]
                aid = session["attachment"]["id"]
                if first or response["refresh"] or urgent or (relevant and time.monotonic() - self.last_progress.get(aid, 0) >= 2):
                    await self.render(session, principal)
                    self.last_progress[aid] = time.monotonic()
                self.sessions[aid] = session
                for event in urgent:
                    await self.post_once("event-" + stable_id(response["epoch"], event["cursor"]), principal,
                        session["attachment"]["slackThread"], f"{session['title']} · {session['project']}: " +
                        ("input needed" if event["kind"] == "attention" else session.get("lastTurnStatus") or event["kind"]), binding=self.binding(session))
            for key, post in list(self.journal.data["posts"].items()):
                if post["status"] == "retryable" and post.get("retryAt", 0) <= time.time() and post.get("retry", {}).get("principal") == principal:
                    retry = post["retry"]
                    try:
                        await self.post_once(key, principal, retry["root"], retry["text"], retry["blocks"], binding=retry.get("binding"))
                    except StaleAttachment:
                        pass  # Known obsolete delivery has been durably cancelled.
            self.journal.commit(lambda d: d["cursors"].__setitem__(cursor_key, {"cursor": response["cursor"], "epoch": response["epoch"]}))

    async def stop(self):
        # Fence queued SDK callbacks and transport sends BEFORE awaiting locks.
        self.enabled = False
        self.generation += 1
        async with self.lock:
            self.online = False
            for principal in self.principals():
                try:
                    await self.call_api({"action": "offline", "principal": principal})
                except Exception:
                    pass

    def principals(self):
        # One event subscription per workspace/channel, not per allowed user.
        result = {}
        for workspace, channel, user in sorted(self.allowed):
            result.setdefault((workspace, channel), {"workspace": workspace, "channel": channel, "user": user})
        return list(result.values())
