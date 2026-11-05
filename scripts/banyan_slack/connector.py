"""Transport-independent connector. Never launches Codex or injects terminal input."""
import asyncio
import copy
import time
import uuid

from .connector_state import (
    Denied, Journal, RateLimited, StaleAttachment, StaleAway, StaleBrowser,
    StaleNativeState, Unavailable, plain, section, stable_id,
)
from .session_browser import SessionBrowserMixin


class Connector(SessionBrowserMixin):
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
        self.away_ready = {}
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

    async def call_browser(self, body):
        try:
            return await self.api.browser(body)
        except Denied:
            principal = body.get("principal", {})
            self.denied_principals.add(tuple(principal.get(k, "") for k in ("workspace", "channel", "user")))
            self.authorization_denied = True
            self.online = False
            raise

    async def check_browser(self, principal, binding):
        if not binding:
            return
        await self.check(principal)
        current = await self.call_browser({"action": "open", "principal": principal, "sessionID": binding["sessionID"]})
        attachment = current.get("attachment") or {}
        if current.get("binding") != binding["identity"]:
            raise StaleBrowser("Conversation changed")
        if binding.get("slackThread") is None:
            if attachment:
                raise StaleBrowser("Conversation already has a thread")
        elif attachment.get("slackThread") != binding["slackThread"]:
            raise StaleBrowser("Thread binding changed")
        if binding.get("requestID"):
            current_request = await self.call_browser({"action": "decision", "principal": principal,
                "sessionID": binding["sessionID"], "identity": binding["identity"], "slackThread": binding["slackThread"]})
            if current_request.get("requestID") != binding["requestID"] or not current_request.get("answerable"):
                raise StaleBrowser("Decision is no longer pending")
        if not self.permitted(principal) or not self.socket_synchronized:
            raise Unavailable("Control disabled")

    @staticmethod
    def native_control_signature(session):
        return stable_id(session.get("available"), session.get("turnID"), session.get("needsAttention"), session.get("requests", []))

    async def check_native_state(self, principal, binding, signature):
        if signature is None:
            return
        await self.check(principal, binding=binding)
        current = await self.call_api({"action": "snapshot", "principal": principal, **binding})
        if self.binding(current) != binding or self.native_control_signature(current) != signature:
            raise StaleNativeState("Native request or turn changed")

    @staticmethod
    def away_digest(snapshot):
        rows = sorted(snapshot.get("sessions", []), key=lambda item: item["sessionID"])
        decisions = sorted(snapshot.get("decisions", []), key=lambda item: item["sessionID"])
        names = {row["sessionID"]: f"{row['project']} · {row['title']}" for row in rows}
        lines = ["Away catch-up"]
        lines.extend(f"{names[row['sessionID']]}: {row['status']}" for row in rows)
        for decision in decisions:
            label = names.get(decision["sessionID"], decision["sessionID"])
            question = decision.get("question") or "Decision needs attention"
            lines.append(f"Needs you — {label}: {question}")
        text = "\n".join(lines)
        return text if len(text) <= 2600 else text[:2570] + "\n[Catch-up truncated]"

    async def check_away(self, principal, guard):
        if not guard:
            return
        body = {"action": "awayCheck", "principal": principal}
        if guard.get("sessionID"):
            body["sessionID"] = guard["sessionID"]
        state = await self.call_browser(body)
        if not state.get("allowed") or state.get("activationID") != guard.get("activationID") or state.get("revision") != guard.get("revision"):
            raise StaleAway("Away or its scope changed")
        if guard.get("requirePending"):
            current = await self.call_browser({"action": "awaySession", "principal": principal, "sessionID": guard["sessionID"]})
            if not current.get("pending") or current.get("activationID") != guard.get("activationID") or current.get("revision") != guard.get("revision"):
                raise StaleAway("Decision is no longer pending")
        if guard.get("snapshotFingerprint"):
            snapshot = await self.call_browser({"action": "awaySnapshot", "principal": principal})
            if stable_id(self.away_digest(snapshot)) != guard["snapshotFingerprint"]:
                raise StaleAway("Catch-up changed before delivery")
        if not self.permitted(principal) or not self.socket_synchronized:
            raise Unavailable("Control disabled")

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

    async def post_once(self, key, principal, root, text, blocks=None, binding=None, browser_binding=None, away_guard=None, native_guard=None):
        await self.check(principal, binding=binding)
        try:
            await self.check_browser(principal, browser_binding)
            await self.check_native_state(principal, binding, native_guard)
            await self.check_away(principal, away_guard)
        except (StaleBrowser, StaleAway):
            if self.journal.data["posts"].get(key, {}).get("status") == "retryable":
                self.journal.commit(lambda d: d["posts"][key].update(status="cancelled"))
            raise
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
            try:
                await self.check_browser(principal, browser_binding)
                await self.check_native_state(principal, binding, native_guard)
                await self.check_away(principal, away_guard)
            except (StaleBrowser, StaleAway):
                if self.journal.data["posts"].get(key, {}).get("status") == "retryable":
                    self.journal.commit(lambda d: d["posts"][key].update(status="cancelled"))
                raise
            self.journal.commit(lambda d: d["posts"].__setitem__(key, {
                "status": "sending", "channel": principal["channel"], "root": root, "binding": binding,
                "sessionID": browser_binding.get("sessionID") if browser_binding else None,
                "browser_binding": browser_binding, "away_guard": away_guard, "native_guard": native_guard}))
            try:
                self.last_post[principal["channel"]] = time.monotonic()
                fields = {"channel": principal["channel"]}
                if root is not None:
                    fields["thread_ts"] = root
                result = await self.slack.call("chat.postMessage", **fields,
                    text=str(text).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")[:3000],
                    blocks=blocks or [section(text)], parse="none", unfurl_links=False, unfurl_media=False,
                    metadata={"event_type": "banyan_remote", "event_payload": {"delivery_id": key}})
                ts = result["ts"]
                self.journal.commit(lambda d: d["posts"][key].update(status="sent", ts=ts))
                return ts
            except RateLimited as error:
                self.journal.commit(lambda d: d["posts"][key].update(status="retryable", retryAt=time.time() + error.retry_after,
                    retry={"principal": principal, "root": root, "text": text, "blocks": blocks, "binding": binding,
                           "browser_binding": browser_binding, "away_guard": away_guard, "native_guard": native_guard}))
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
            if event.get("type") == "app_home_opened" and event.get("tab", "home") == "home":
                principal = self.home_principal(payload.get("team_id", ""), event.get("user", ""))
                if principal:
                    await self.show_home(principal)
                return
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
                if command == "list" or command.startswith("list "):
                    query = command[4:].strip()
                    result = await self.call_browser({"action": "list", "principal": principal, "query": query, "limit": 10})
                    blocks = [section("Banyan sessions" + (f" · search: {query}" if query else ""))]
                    for item in result["sessions"]:
                        blocks.append(self.browser_row(item, principal, owner=None))
                    if result.get("nextOffset") is not None:
                        blocks.append(section("More sessions are available in App Home."))
                    await self.post_once(key, principal, root, "Banyan sessions", blocks)
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
            if not session:
                stored = self.journal.data["browserThreads"].get(stable_id(principal["workspace"], principal["channel"], root))
                if not stored or event.get("ts") == root or not text.strip():
                    return
                if stored.get("identity", {}).get("kind") == "nativeCodex":
                    session = await self.attach_native_for_reply(principal, stored, key)
                    if not session:
                        return
                else:
                    await self.browser_followup(principal, stored, key, text)
                    return
            if event.get("ts") == root or not text.strip():
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
        actions = payload.get("actions", [])
        if payload.get("type") == "block_actions" and len(actions) == 1 and actions[0].get("action_id") in ("banyan_home", "banyan_home_search", "banyan_browser"):
            await self.browser_interaction(payload, workspace, user, actions[0])
            return
        if payload.get("type") == "view_submission":
            token = payload.get("view", {}).get("private_metadata", "")
            modal = self.journal.data["modals"].get(token)
            if not modal or modal["principal"]["workspace"] != workspace or modal["principal"]["user"] != user:
                return
            principal = modal["principal"]  # Channel comes from trusted opening action, never button JSON.
            if modal.get("kind") == "puck":
                await self.submit_puck_question(payload, modal, token, principal)
                return
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

    async def open_puck_question(self, principal, binding, decision, trigger):
        questions = decision.get("questions", [])
        if not trigger or not questions or len(questions) > 12:
            return
        blocks = []
        for index, question in enumerate(questions):
            text, options = str(question.get("question", "")), question.get("options", [])
            custom, multiple = bool(question.get("custom")), bool(question.get("multiple"))
            if not text or len(text) > 2000 or len(options) > 100 or (not options and not custom) or any(
                    not item.get("label") or len(item["label"]) > 75 for item in options):
                return
            if options:
                element = {"type": "multi_static_select" if multiple else "static_select", "action_id": "choice",
                    "options": [{"text": plain(item["label"]), "value": item["label"]} for item in options]}
                blocks.append({"type": "input", "block_id": f"q{index}-choice", "optional": custom,
                               "label": plain(text), "element": element})
            if custom:
                blocks.append({"type": "input", "block_id": f"q{index}-custom", "optional": bool(options),
                    "label": plain("Other answer: " + text[:1900]),
                    "element": {"type": "plain_text_input", "action_id": "custom", "multiline": True, "max_length": 4000}})
        token = str(uuid.uuid4())
        body = {**binding, "requestID": decision["requestID"], "option": 1}
        self.journal.commit(lambda d: d["modals"].__setitem__(token, {"kind": "puck", "body": body,
            "principal": principal, "forms": [{"multiple": bool(q.get("multiple")), "custom": bool(q.get("custom"))}
                                                    for q in questions]}))
        await self.check_browser(principal, {**binding, "requestID": decision["requestID"]})
        await self.slack.call("views.open", trigger_id=trigger, view={"type": "modal", "callback_id": "banyan_puck_answer",
            "private_metadata": token, "title": plain("Answer Puck"), "submit": plain("Send"), "blocks": blocks})

    async def submit_puck_question(self, payload, modal, token, principal):
        await self.check(principal)
        values = (payload.get("view") or {}).get("state", {}).get("values", {})
        selections = []
        valid = True
        for index, form in enumerate(modal["forms"]):
            choice = values.get(f"q{index}-choice", {}).get("choice", {})
            selected = choice.get("selected_options")
            if selected is None:
                one = choice.get("selected_option")
                selected = [one] if one else []
            labels = [item.get("value", "") for item in selected]
            custom = values.get(f"q{index}-custom", {}).get("custom", {}).get("value") or None
            text = custom.strip() if custom else ""
            if (text and (not form["custom"] or labels)) or (not text and (not labels or (not form["multiple"] and len(labels) != 1))):
                valid = False
            selections.append({"labels": labels, "text": custom})
        body = {**modal["body"], "selections": selections}
        operation = stable_id(principal["workspace"], principal["user"], payload["view"]["id"], token)
        binding = {key: body[key] for key in ("sessionID", "identity", "slackThread")}
        if not valid:
            await self.post_once("browser-answer-invalid-" + operation, principal, binding["slackThread"],
                "Answer not sent: choose offered options or enter a custom answer for each question.",
                browser_binding={**binding, "requestID": body["requestID"]})
            return
        result = await self.answer_browser(principal, body, operation)
        await self.post_once("browser-answer-receipt-" + operation, principal, binding["slackThread"],
                             "Answer: " + result.get("status", "uncertain"), browser_binding=binding)
        await self.render_terminal_decision(principal, binding)

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

    async def render(self, session, principal, notify=None, away_guard=None):
        binding = self.binding(session)
        await self.check(principal, binding=binding)
        await self.check_away(principal, away_guard)
        session = await self.call_api({"action": "snapshot", "principal": principal, **binding})
        if self.binding(session) != binding:
            raise StaleAttachment("Attachment changed")
        signature = self.native_control_signature(session)
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
        try:
            ts = await self.post_once(key, principal, attachment["slackThread"], heading + ": " + state, blocks[:50],
                                      binding=binding, away_guard=away_guard, native_guard=signature)
            if ts:
                await self.check_native_state(principal, binding, signature)
                await self.check_away(principal, away_guard)
                await self.slack.call("chat.update", channel=principal["channel"], ts=ts,
                    text=heading.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;") + ": " + state, blocks=blocks[:50], parse="none")
                self.journal.commit(lambda d: d["posts"][key].update(native_guard=signature, controlsRetired=False))
            if notify:
                await self.post_once("notice-" + stable_id(attachment["id"], notify), principal,
                    attachment["slackThread"], heading + ": " + state, binding=binding, away_guard=away_guard, native_guard=signature)
        except StaleNativeState:
            # If an old panel exists, remove its controls; do not publish the
            # stale snapshot or automatically post a replacement.
            ts = self.journal.data["posts"].get(key, {}).get("ts")
            if ts:
                await self.check(principal, binding=binding)
                await self.check_away(principal, away_guard)
                await self.slack.call("chat.update", channel=principal["channel"], ts=ts,
                    text="Native session changed. Refresh to continue.",
                    blocks=[section("Native session changed. Controls are paused until refreshed.")], parse="none")
                self.journal.commit(lambda d: d["posts"][key].update(native_guard=None, controlsRetired=True))

    async def retire_obsolete_native_card(self, session, principal):
        binding = self.binding(session)
        key = "status-" + session["attachment"]["id"]
        post = self.journal.data["posts"].get(key, {})
        signature = post.get("native_guard")
        if not post.get("ts") or post.get("controlsRetired") or (signature is not None and signature == self.native_control_signature(session)):
            return
        await self.check(principal, binding=binding)
        await self.slack.call("chat.update", channel=principal["channel"], ts=post["ts"],
            text="Native session changed. Refresh to continue.",
            blocks=[section("Native session changed. Controls are paused until refreshed.")], parse="none")
        self.journal.commit(lambda d: d["posts"][key].update(native_guard=None, controlsRetired=True))

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

    async def refresh_away(self, principal):
        cursor_key = "away-" + stable_id(principal["workspace"], principal["channel"])
        async with self.lock:
            if not self.permitted(principal) or not self.socket_synchronized:
                return
            connection = self.connection_generation
            saved = self.journal.data["cursors"].get(cursor_key, {})
        # This request is parked by Banyan until a status or scope change.
        response = await self.call_browser({"action": "awayEvents", "principal": principal, **saved})
        async with self.lock:
            if not self.permitted(principal) or not self.socket_synchronized or connection != self.connection_generation:
                return
            await self.check(principal)
            channel_key = (principal["workspace"], principal["channel"])
            await self.retire_obsolete_browser_cards(principal, response.get("events", []), response.get("refreshCards", False))
            if not response.get("enabled"):
                self.away_ready.pop(channel_key, None)
                self.save_away_cursor(cursor_key, response)
                return
            guard = {"activationID": response["activationID"], "revision": response["revision"]}
            if response.get("refresh") or self.away_ready.get(channel_key) != guard["activationID"]:
                snapshot = await self.call_browser({"action": "awaySnapshot", "principal": principal})
                if snapshot.get("activationID") != guard["activationID"] or snapshot.get("revision") != guard["revision"]:
                    raise StaleAway("Away changed during catch-up")
                self.away_ready.pop(channel_key, None)
                await self.deliver_away_catchup(principal, guard, snapshot)
                await self.process_away_events(principal, guard, snapshot.get("events", []), snapshot["epoch"])
                self.away_ready[channel_key] = guard["activationID"]
                self.save_away_cursor(cursor_key, {**snapshot, "enabled": True})
            else:
                await self.process_away_events(principal, guard, response.get("events", []), response["epoch"])
                self.save_away_cursor(cursor_key, response)

    async def retire_obsolete_browser_cards(self, principal, events, refresh_all):
        """Remove stale controls from already published cards without a new post.

        This maintenance runs even when Away is off. New decisions are shown
        only after an explicit open or through enabled Away delivery.
        """
        changed = {event.get("sessionID") for event in events}
        for thread_key, binding in list(self.journal.data["browserThreads"].items()):
            if thread_key != stable_id(principal["workspace"], principal["channel"], binding.get("slackThread")):
                continue
            if binding.get("identity", {}).get("kind") not in ("terminalCodex", "puck"):
                continue
            if not refresh_all and binding.get("sessionID") not in changed:
                continue
            key = "browser-decision-" + stable_id(principal["workspace"], principal["channel"], binding)
            post = self.journal.data["posts"].get(key, {})
            if not post.get("ts") or not (post.get("browser_binding") or {}).get("requestID"):
                continue
            old_id = post["browser_binding"]["requestID"]
            try:
                await self.check_browser(principal, binding)
                current = await self.call_browser({"action": "decision", "principal": principal, **binding})
                if current.get("requestID") == old_id and current.get("status") == "pending" and current.get("answerable"):
                    continue
            except Unavailable:
                # A local policy refusal must still prevent the content-free
                # update; the fresh check below enforces that boundary.
                pass
            await self.check(principal)
            await self.slack.call("chat.update", channel=principal["channel"], ts=post["ts"],
                text="Decision resolved or unavailable.",
                blocks=[section("Decision resolved or unavailable. No answer controls are active.")], parse="none")
            self.journal.commit(lambda d: d["posts"][key].update(browser_binding=binding))

    def save_away_cursor(self, key, response):
        value = {"eventEpoch": response["epoch"], "eventCursor": response["cursor"],
                 "awayActivationID": response.get("activationID"), "awayRevision": response["revision"]}
        self.journal.commit(lambda d: d["cursors"].__setitem__(key, value))

    async def deliver_away_catchup(self, principal, guard, snapshot):
        text = self.away_digest(snapshot)
        digest_guard = {**guard, "snapshotFingerprint": stable_id(text)}
        key = "away-digest-" + stable_id(principal["workspace"], principal["channel"], guard["activationID"])
        await self.post_once(key, principal, None, text, away_guard=digest_guard)
        if snapshot.get("gap"):
            gap_key = "away-gap-" + stable_id(principal["workspace"], principal["channel"], guard["activationID"], snapshot["epoch"])
            await self.post_once(gap_key, principal, None,
                "Some activity could not be recovered. Current session state was refreshed.", away_guard=guard)
        rows = {row["sessionID"]: row for row in snapshot.get("sessions", [])}
        for candidate in snapshot.get("decisions", []):
            row = rows.get(candidate.get("sessionID"))
            if not row:
                continue
            session_guard = {**guard, "sessionID": row["sessionID"], "requirePending": True}
            try:
                current = await self.call_browser({"action": "awaySession", "principal": principal, "sessionID": row["sessionID"]})
                if not current.get("pending"):
                    continue
                await self.open_browser_session(principal, current, away_guard=session_guard, observe_native=True)
                await self.mark_away_decision_seen(principal, guard, row["sessionID"])
            except (StaleAway, StaleBrowser):
                # Resolution or scope changes retire the candidate, never expose controls.
                continue

    async def mark_away_decision_seen(self, principal, guard, session_id):
        opened = await self.call_browser({"action": "open", "principal": principal, "sessionID": session_id})
        identity, attachment = opened.get("binding"), opened.get("attachment") or {}
        if not identity or not attachment.get("slackThread"):
            return
        if identity.get("kind") == "nativeCodex":
            native = next((s for s in self.sessions.values() if s["sessionID"] == session_id and
                s["threadID"] == identity["conversationID"] and s["attachment"]["slackThread"] == attachment["slackThread"]), None)
            if native:
                native = await self.call_api({"action": "snapshot", "principal": principal, **self.binding(native)})
                keys = [stable_id("native", guard["activationID"], session_id, item["id"], item.get("turnID"))
                        for item in native.get("requests", []) if item.get("answerable", True)]
                if keys:
                    self.journal.commit(lambda d: d["awaySeen"].update({key: True for key in keys}))
            return
        if identity.get("kind") not in ("terminalCodex", "puck"):
            return
        binding = {"sessionID": session_id, "identity": identity, "slackThread": attachment["slackThread"]}
        decision = await self.call_browser({"action": "decision", "principal": principal, **binding})
        if decision.get("answerable") and decision.get("requestID"):
            key = stable_id(guard["activationID"], session_id, decision["requestID"])
            self.journal.commit(lambda d: d["awaySeen"].__setitem__(key, True))

    async def process_away_events(self, principal, guard, events, epoch):
        # Current state wins over transient status bursts; no progress stream is posted.
        latest = {}
        completed = set()
        for event in events:
            latest[event["sessionID"]] = event
            if event.get("status") == "need-input" and event.get("previousStatus") in ("running", "executing", "long-running-shell", "subagents"):
                completed.add(event["sessionID"])
        for session_id, event in latest.items():
            session_guard = {**guard, "sessionID": session_id}
            try:
                await self.check_away(principal, session_guard)
                current = await self.call_browser({"action": "awaySession", "principal": principal, "sessionID": session_id})
                if current.get("backend") == "codex" and not current.get("pending") and any(
                        session.get("sessionID") == session_id and session.get("attachment", {}).get("workspace") == principal["workspace"]
                        and session.get("attachment", {}).get("channel") == principal["channel"] for session in self.sessions.values()):
                    continue  # Attached native sessions already have their own event stream.
                if current.get("pending"):
                    pending_guard = {**session_guard, "requirePending": True}
                    opened = await self.call_browser({"action": "open", "principal": principal, "sessionID": session_id})
                    identity, attachment = opened.get("binding"), opened.get("attachment") or {}
                    old_binding = {"sessionID": session_id, "identity": identity, "slackThread": attachment.get("slackThread")}
                    old_key = "browser-decision-" + stable_id(principal["workspace"], principal["channel"], old_binding)
                    had_card = bool(self.journal.data["posts"].get(old_key, {}).get("ts"))
                    await self.open_browser_session(principal, current, away_guard=pending_guard, observe_native=True)
                    if current.get("backend") == "codex":
                        await self.mark_away_decision_seen(principal, guard, session_id)
                        continue  # Subsequent native events use the existing stream.
                    opened = await self.call_browser({"action": "open", "principal": principal, "sessionID": session_id})
                    identity, attachment = opened.get("binding"), opened.get("attachment") or {}
                    if not identity or not attachment.get("slackThread") or identity.get("kind") not in ("terminalCodex", "puck"):
                        continue
                    binding = {"sessionID": session_id, "identity": identity, "slackThread": attachment["slackThread"]}
                    decision = await self.call_browser({"action": "decision", "principal": principal, **binding})
                    request_id = decision.get("requestID") if decision.get("answerable") else None
                    if not request_id:
                        continue
                    seen = stable_id(guard["activationID"], session_id, request_id)
                    if seen not in self.journal.data["awaySeen"]:
                        if had_card:
                            await self.post_once("away-decision-" + seen, principal, binding["slackThread"],
                                "A new decision needs your attention.",
                                browser_binding={**binding, "requestID": request_id}, away_guard=pending_guard)
                        self.journal.commit(lambda d: d["awaySeen"].__setitem__(seen, True))
                elif (current.get("status") in ("failed", "completed") or
                      (current.get("status") == "need-input" and session_id in completed)) and current.get("status") == event.get("status"):
                    await self.open_browser_session(principal, current, away_guard=session_guard)
                    opened = await self.call_browser({"action": "open", "principal": principal, "sessionID": session_id})
                    identity, attachment = opened.get("binding"), opened.get("attachment") or {}
                    if identity and attachment.get("slackThread"):
                        binding = {"sessionID": session_id, "identity": identity, "slackThread": attachment["slackThread"]}
                        await self.post_once("away-event-" + stable_id(epoch, event["cursor"]), principal, binding["slackThread"],
                            f"{current['title']}: {'completed' if current['status'] == 'need-input' else current['status']}",
                            browser_binding=binding, away_guard=session_guard)
                else:
                    # Refresh an existing card to remove controls after desktop resolution.
                    for key, binding in list(self.journal.data["browserThreads"].items()):
                        if binding.get("sessionID") == session_id and key == stable_id(principal["workspace"], principal["channel"], binding.get("slackThread")) and binding.get("identity", {}).get("kind") in ("terminalCodex", "puck"):
                            await self.render_terminal_decision(principal, binding, away_guard=session_guard)
            except (StaleAway, StaleBrowser):
                continue

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
            away = await self.call_browser({"action": "awayStatus", "principal": principal})
            channel_key = (principal["workspace"], principal["channel"])
            ready = away.get("enabled") and self.away_ready.get(channel_key) == away.get("activationID")
            for session in current.values():
                relevant = [e for e in response["events"] if e["attachment"]["id"] == session["attachment"]["id"]]
                urgent = [e for e in relevant if e["kind"] in ("attention", "turn/completed", "error")]
                aid = session["attachment"]["id"]
                self.sessions[aid] = session
                if not ready:
                    if relevant or first:
                        await self.retire_obsolete_native_card(session, principal)
                    continue
                guard = {"activationID": away["activationID"], "revision": away["revision"], "sessionID": session["sessionID"]}
                try:
                    await self.check_away(principal, guard)
                    if relevant:
                        session = await self.call_api({"action": "snapshot", "principal": principal, **self.binding(session)})
                        self.sessions[aid] = session
                    if urgent or (relevant and time.monotonic() - self.last_progress.get(aid, 0) >= 2):
                        await self.render(session, principal, away_guard=guard)
                        self.last_progress[aid] = time.monotonic()
                    signature = self.native_control_signature(session)
                    for event in urgent:
                        seen_keys = []
                        event_guard = guard
                        if event["kind"] == "attention":
                            pending = [item for item in session.get("requests", []) if item.get("answerable", True)]
                            seen_keys = [stable_id("native", guard["activationID"], session["sessionID"], item["id"], item.get("turnID")) for item in pending]
                            if not seen_keys or all(key in self.journal.data["awaySeen"] for key in seen_keys):
                                continue
                            event_guard = {**guard, "requirePending": True}
                        elif event["kind"] == "turn/completed" and (session.get("turnID") or session.get("lastTurnStatus") != "completed"):
                            continue
                        elif event["kind"] == "error" and session.get("lastTurnStatus") not in ("failed", "interrupted") and session.get("state") not in ("failed", "systemError"):
                            continue
                        await self.post_once("event-" + stable_id(response["epoch"], event["cursor"]), principal,
                            session["attachment"]["slackThread"], f"{session['title']} · {session['project']}: " +
                            ("input needed" if event["kind"] == "attention" else session.get("lastTurnStatus") or event["kind"]),
                            binding=self.binding(session), away_guard=event_guard, native_guard=signature)
                        if seen_keys:
                            self.journal.commit(lambda d: d["awaySeen"].update({key: True for key in seen_keys}))
                except (StaleAway, StaleNativeState):
                    continue
            for key, post in list(self.journal.data["posts"].items()):
                if post["status"] == "retryable" and post.get("retryAt", 0) <= time.time() and post.get("retry", {}).get("principal") == principal:
                    retry = post["retry"]
                    try:
                        await self.post_once(key, principal, retry["root"], retry["text"], retry["blocks"], binding=retry.get("binding"),
                                             browser_binding=retry.get("browser_binding"), away_guard=retry.get("away_guard"), native_guard=retry.get("native_guard"))
                    except (StaleAttachment, StaleBrowser, StaleAway, StaleNativeState):
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
