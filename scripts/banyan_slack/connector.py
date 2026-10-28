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
import unicodedata


class Unavailable(Exception):
    """Safe, content-free error for local status reporting."""


class Denied(Unavailable):
    """An authoritative authorization refusal, distinct from transport loss."""


class StaleAttachment(Unavailable):
    """Authoritative snapshot refused an obsolete attachment binding."""


class StaleBrowser(Unavailable):
    """The session-to-thread binding is no longer authoritative."""


class StaleNativeState(Unavailable):
    """The native turn or pending requests changed before delivery."""


class StaleAway(Unavailable):
    """Away is off, its scope changed, or the event is obsolete."""


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
        # Older native-only journals have no session-browser mappings.
        self.data.setdefault("browserThreads", {})
        self.data.setdefault("awaySeen", {})
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

    def home_principal(self, workspace, user):
        matches = [(w, c, u) for w, c, u in self.allowed if w == workspace and u == user]
        # App Home has no control-channel ID. Do not guess when multiple tuples match.
        if len(matches) != 1:
            return None
        w, c, u = matches[0]
        principal = {"workspace": w, "channel": c, "user": u}
        return principal if self.permitted(principal) else None

    def browser_button(self, label, body, principal, *, home=False):
        return {"type": "button", "action_id": "banyan_home" if home else "banyan_browser",
                "text": plain(label), "value": self.control(body, principal)}

    def browser_row(self, item, principal, owner):
        body = {"action": "browser_open", "sessionID": item["sessionID"],
                "title": item["title"], "project": item["project"], "owner": owner}
        return {"type": "section", "text": plain(f"{item['title']} · {item['status']}" +
                    (" · Needs you" if item.get("needsAttention") else "")),
                "accessory": self.browser_button("Open", body, principal, home=owner is not None)}

    async def show_home(self, principal, *, query="", filter_name="all", offset=0, notice=None):
        await self.check(principal)
        # Slack input can contain multibyte characters; the local API caps bytes.
        query = str(query).encode("utf-8")[:256].decode("utf-8", "ignore")
        result = await self.call_browser({"action": "list", "principal": principal, "query": query,
                                          "filter": filter_name, "offset": max(0, offset), "limit": 10})
        away = await self.call_browser({"action": "awayStatus", "principal": principal})
        state = {"action": "home", "owner": principal["user"], "query": query, "filter": filter_name, "offset": offset}
        token = self.control(state, principal)
        search = {"type": "plain_text_input", "action_id": "banyan_home_search", "max_length": 256,
                  "dispatch_action_config": {"trigger_actions_on": ["on_enter_pressed"]}}
        if query:
            search["initial_value"] = query
        blocks = [section("Banyan sessions"),
                  {"type": "input", "dispatch_action": True, "label": plain("Search sessions"), "element": search}]
        if notice:
            blocks.append(section(notice))
        blocks.append(section("Away is on" if away.get("enabled") else "Away is off"))
        blocks.append({"type": "actions", "elements": [self.browser_button(
            "Turn Away off" if away.get("enabled") else "Turn Away on",
            {**state, "action": "away_toggle", "enabled": not away.get("enabled")}, principal, home=True)]})
        filters = []
        for label, value in (("Needs you", "needs"), ("Working", "working"), ("Recent", "recent"), ("All", "all")):
            filters.append(self.browser_button(label, {**state, "filter": value, "offset": 0}, principal, home=True))
        blocks.append({"type": "actions", "elements": filters})
        project = None
        for item in result["sessions"]:
            if item["project"] != project:
                project = item["project"]
                blocks.append(section(project))
            blocks.append(self.browser_row(item, principal, owner=principal["user"]))
            following = item["sessionID"] in away.get("sessionIDs", [])
            project_followed = item.get("projectID") in away.get("projectIDs", [])
            follow_actions = [self.browser_button("Unfollow" if following else "Follow", {**state, "action": "away_follow",
                "sessionID": item["sessionID"], "follow": not following}, principal, home=True)]
            if item.get("projectID"):
                follow_actions.append(self.browser_button("Unfollow project" if project_followed else "Follow project",
                    {**state, "action": "away_follow_project", "projectID": item["projectID"], "follow": not project_followed}, principal, home=True))
            blocks.append({"type": "actions", "elements": follow_actions})
        if not result["sessions"]:
            blocks.append(section("No matching sessions."))
        navigation = []
        if offset > 0:
            navigation.append(self.browser_button("Previous", {**state, "offset": max(0, offset - 10)}, principal, home=True))
        if result.get("nextOffset") is not None:
            navigation.append(self.browser_button("Next", {**state, "offset": result["nextOffset"]}, principal, home=True))
        if navigation:
            blocks.append({"type": "actions", "elements": navigation})
        await self.check(principal)
        await self.slack.call("views.publish", user_id=principal["user"], view={"type": "home", "private_metadata": token, "blocks": blocks})

    async def browser_interaction(self, payload, workspace, user, action):
        action_id = action.get("action_id")
        if action_id in ("banyan_home", "banyan_home_search"):
            token = (payload.get("view") or {}).get("private_metadata") if action_id == "banyan_home_search" else action.get("value")
            descriptor = self.journal.data["controls"].get(token)
            if not descriptor or descriptor["workspace"] != workspace or descriptor["body"].get("owner") != user:
                return
            principal = {"workspace": workspace, "channel": descriptor["channel"], "user": user}
        else:
            channel = (payload.get("channel") or {}).get("id", "")
            principal = {"workspace": workspace, "channel": channel, "user": user}
            descriptor = self.journal.data["controls"].get(action.get("value"))
            if not descriptor or descriptor["workspace"] != workspace or descriptor["channel"] != channel:
                return
        if not self.permitted(principal):
            return
        await self.check(principal)
        body = descriptor["body"]
        if action_id == "banyan_home_search":
            await self.show_home(principal, query=action.get("value") or "", filter_name=body.get("filter", "all"))
        elif body.get("action") == "home":
            await self.show_home(principal, query=body.get("query", ""), filter_name=body.get("filter", "all"), offset=body.get("offset", 0))
        elif body.get("action") in ("away_toggle", "away_follow", "away_follow_project"):
            update = {"action": "awayConfigure", "principal": principal}
            if body["action"] == "away_toggle":
                if body.get("enabled"):
                    current = await self.call_browser({"action": "awayStatus", "principal": principal})
                    if not current.get("sessionIDs") and not current.get("projectIDs"):
                        await self.show_home(principal, query=body.get("query", ""), filter_name=body.get("filter", "all"),
                                             offset=body.get("offset", 0), notice="Follow a session or project before turning Away on.")
                        return
                update["awayEnabled"] = body.get("enabled", False)
            elif body["action"] == "away_follow":
                update.update(followSessionID=body["sessionID"], follow=body["follow"])
            else:
                update.update(followProjectID=body["projectID"], follow=body["follow"])
            await self.call_browser(update)
            await self.show_home(principal, query=body.get("query", ""), filter_name=body.get("filter", "all"), offset=body.get("offset", 0))
        elif body.get("action") == "browser_open":
            notice = await self.open_browser_session(principal, body)
            if action_id == "banyan_home":
                await self.show_home(principal, notice=notice)
        elif body.get("action") == "browser_page":
            await self.post_browser_page(principal, body)
        elif body.get("action") == "puck_question":
            binding = {"sessionID": body["sessionID"], "identity": body["identity"], "slackThread": body["slackThread"]}
            decision = await self.call_browser({"action": "decision", "principal": principal, **binding})
            if decision.get("requestID") == body.get("requestID") and decision.get("answerable"):
                await self.open_puck_question(principal, binding, decision, payload.get("trigger_id"))
        elif body.get("action") == "browser_answer":
            operation = stable_id(workspace, principal["channel"], user,
                (payload.get("container") or {}).get("message_ts"), action.get("action_id"), action.get("action_ts"))
            result = await self.answer_browser(principal, body, operation)
            guard = {"sessionID": body["sessionID"], "identity": body["identity"], "slackThread": body["slackThread"]}
            await self.post_once("browser-answer-receipt-" + operation, principal, body["slackThread"],
                                 "Answer: " + result.get("status", "uncertain"), browser_binding=guard)
            await self.render_terminal_decision(principal, guard)

    async def bind_browser(self, key, body):
        old = self.journal.data["incoming"].get(key)
        if old:
            if old.get("body") != body:
                raise Unavailable("Duplicate binding changed payload")
            if old.get("status") == "done":
                return old.get("result")
            # An uncertain local bind is reconciled by readback, never replayed.
            current = await self.call_browser({"action": "open", "principal": body["principal"], "sessionID": body["sessionID"]})
            attachment = current.get("attachment") or {}
            if current.get("binding") == body["identity"] and attachment.get("slackThread") == body["slackThread"]:
                result = {"attachment": attachment}
                self.journal.commit(lambda d: d["incoming"][key].update(status="done", result=result))
                return result
            return None
        self.journal.commit(lambda d: d["incoming"].__setitem__(key, {"status": "sending", "body": body}))
        try:
            result = await self.call_browser(body)
            receipt = {"attachment": result.get("attachment")}
            self.journal.commit(lambda d: d["incoming"][key].update(status="done", result=receipt))
            return receipt
        except (Exception, asyncio.CancelledError):
            self.journal.commit(lambda d: d["incoming"][key].update(status="uncertain"))
            raise

    async def open_browser_session(self, principal, body, away_guard=None, observe_native=False):
        await self.check_away(principal, away_guard)
        session_id = body["sessionID"]
        opened = await self.call_browser({"action": "open", "principal": principal, "sessionID": session_id})
        identity = opened.get("binding")
        if not identity:
            return "The current conversation could not be bound safely. Read it on the Mac."
        attachment = opened.get("attachment") or {}
        root = attachment.get("slackThread")
        guard = {"sessionID": session_id, "identity": identity, "slackThread": None}
        if not root:
            key = "browser-root-" + stable_id(principal["workspace"], principal["channel"], session_id, identity)
            root = await self.post_once(key, principal, None,
                f"{body['project']} · {body['title']}\nSession: {session_id}", browser_binding=guard, away_guard=away_guard)
            if not root:
                return "Thread creation is uncertain. Inspect the control channel before reconciling."
            bind = {"action": "bind", "principal": principal, "sessionID": session_id, "identity": identity, "slackThread": root}
            await self.check_away(principal, away_guard)
            receipt = await self.bind_browser("browser-bind-" + stable_id(principal["workspace"], principal["channel"], session_id, identity, root), bind)
            if not receipt or not receipt.get("attachment"):
                return "Thread binding is uncertain. Reconcile before retrying."
            attachment = receipt["attachment"]
        else:
            # A prior bind response may have been lost after Banyan committed.
            # Fresh readback proves the mapping and closes that receipt without
            # resubmitting the bind or creating another Slack root.
            bind_key = "browser-bind-" + stable_id(principal["workspace"], principal["channel"], session_id, identity, root)
            old = self.journal.data["incoming"].get(bind_key)
            if old and old.get("status") == "uncertain":
                self.journal.commit(lambda d: d["incoming"][bind_key].update(status="done", result={"attachment": attachment}))
        thread_key = stable_id(principal["workspace"], principal["channel"], root)
        thread = {"sessionID": session_id, "identity": identity, "slackThread": root}
        self.journal.commit(lambda d: d["browserThreads"].__setitem__(thread_key, thread))
        # Browsing must not subscribe to or resume a native thread. Existing
        # native attachments keep their own runtime-owned control path.
        if identity.get("kind") == "nativeCodex":
            existing = next((s for s in self.sessions.values() if s["sessionID"] == session_id and
                s["threadID"] == identity["conversationID"] and s["attachment"]["slackThread"] == root), None)
            if not existing and observe_native:
                existing = await self.attach_native_for_away(principal, thread, away_guard)
            if existing:
                await self.render(existing, principal, away_guard=away_guard)
        await self.post_browser_page(principal, {"action": "browser_page", "sessionID": session_id,
            "identity": identity, "slackThread": root, "cursor": None}, away_guard=away_guard)
        return "Opened in the configured control channel."

    async def attach_native_for_away(self, principal, binding, away_guard):
        # Following a pending native session is explicit Away behavior. Ordinary
        # history opens never attach or resume it. A lost attach reply is read
        # back through the authoritative mapping and snapshot, never resubmitted.
        await self.check_away(principal, away_guard)
        await self.check_browser(principal, binding)
        native = {"action": "attach", "principal": principal, "sessionID": binding["sessionID"],
                  "threadID": binding["identity"]["conversationID"], "slackThread": binding["slackThread"]}
        key = "browser-native-attach-" + stable_id(principal["workspace"], principal["channel"],
            binding["sessionID"], binding["identity"], binding["slackThread"])
        try:
            result = await self.mutate(key, native)
        except Denied:
            raise
        except Unavailable:
            result = {}
        if not result.get("attachment"):
            opened = await self.call_browser({"action": "open", "principal": principal, "sessionID": binding["sessionID"]})
            attachment = opened.get("attachment") or {}
            if opened.get("binding") != binding["identity"] or attachment.get("slackThread") != binding["slackThread"]:
                return None
            try:
                result = await self.call_api({"action": "snapshot", "principal": principal,
                    "sessionID": binding["sessionID"], "threadID": binding["identity"]["conversationID"],
                    "attachmentID": attachment["id"], "slackThread": binding["slackThread"]})
            except Unavailable:
                return None
        await self.check_away(principal, away_guard)
        await self.check_browser(principal, binding)
        self.sessions[result["attachment"]["id"]] = result
        return result

    async def attach_native_for_reply(self, principal, binding, event_key):
        # An explicit reply may attach the existing native thread; merely
        # opening history never does. An unknown attach outcome fences this
        # specific reply rather than silently queuing it on a later replay.
        barrier = "browser-native-reply-" + event_key
        if barrier in self.journal.data["incoming"]:
            await self.post_once("browser-native-reply-uncertain-" + event_key, principal, binding["slackThread"],
                "Reply not sent: native attachment needs reconciliation.", browser_binding=binding)
            return None
        await self.check_browser(principal, binding)
        native = {"action": "attach", "principal": principal, "sessionID": binding["sessionID"],
                  "threadID": binding["identity"]["conversationID"], "slackThread": binding["slackThread"]}
        key = "browser-native-attach-" + stable_id(principal["workspace"], principal["channel"],
            binding["sessionID"], binding["identity"], binding["slackThread"])
        try:
            result = await self.mutate(key, native)
        except Denied:
            # The incoming Slack event has already been acknowledged. A later
            # re-enable must not turn a denied reply into fresh input.
            self.journal.commit(lambda d: d["incoming"].__setitem__(barrier, {
                "status": "uncertain", "body": {"sessionID": binding["sessionID"]}, "result": {"status": "uncertain"}}))
            raise
        except Exception:
            result = {"status": "uncertain"}
        if not result.get("attachment"):
            self.journal.commit(lambda d: d["incoming"].__setitem__(barrier, {
                "status": "uncertain", "body": {"sessionID": binding["sessionID"]}, "result": {"status": "uncertain"}}))
            await self.post_once("browser-native-reply-uncertain-" + event_key, principal, binding["slackThread"],
                "Reply not sent: native attachment needs reconciliation.", browser_binding=binding)
            return None
        self.sessions[result["attachment"]["id"]] = result
        return result

    async def browser_followup(self, principal, binding, event_key, text):
        # Raw newlines or control characters can be interpreted by a terminal
        # picker; require one printable line until bracketed paste is verified.
        if binding.get("identity", {}).get("kind") == "terminalPane":
            result = {"status": "rejected", "reason": "identity_unverified"}
        elif not text.strip() or len(text.encode("utf-8")) > 16384 or any(
                unicodedata.category(c) in ("Cc", "Cf") and not (binding.get("identity", {}).get("kind") == "puck" and c in "\n\t") for c in text):
            result = {"status": "rejected", "reason": "unsupported_text"}
        else:
            result = await self.submit_browser_followup(principal, binding, event_key, text)
        status = result.get("status", "uncertain")
        reason = result.get("reason")
        if status == "submitted":
            message = "Reply submitted to this session."
        elif status == "rejected" and reason == "identity_unverified":
            message = "Reply not sent: the exact conversation identity is unavailable. Continue on the Mac."
        elif status == "rejected" and reason == "unsupported_text":
            message = "Reply not sent: use one printable line without control characters."
        elif status == "rejected":
            message = "Reply not sent: the pane is busy, unavailable, or changed."
        elif status == "acknowledged":
            message = "This reply was reconciled locally and was not sent again."
        else:
            message = "Reply outcome is uncertain. Inspect the desktop session before reconciling; it will not be retried."
        try:
            ts = await self.post_once("browser-followup-receipt-" + event_key, principal, binding["slackThread"], message,
                                      browser_binding=binding)
            if ts:
                await self.check_browser(principal, binding)
                await self.slack.call("chat.update", channel=principal["channel"], ts=ts,
                                      text=message, blocks=[section(message)], parse="none")
        except StaleBrowser:
            await self.post_once("browser-followup-stale-" + event_key, principal, binding["slackThread"],
                                 "This session binding changed or is unavailable. Reopen it from App Home.")

    def record_browser_receipt(self, key, receipt):
        status = receipt.get("status")
        if status in ("submitted", "rejected", "acknowledged"):
            self.journal.commit(lambda d: d["incoming"][key].update(status="done", result=receipt))
            return receipt
        # Keep an unknown or in-flight result open for read-only reconciliation.
        self.journal.commit(lambda d: d["incoming"][key].update(status="uncertain", result=receipt))
        return receipt if status == "uncertain" else {"status": "uncertain"}

    async def submit_browser_followup(self, principal, binding, operation, text):
        await self.check(principal)
        body = {"action": "followup", "principal": principal, **binding, "operationID": operation, "text": text}
        key = "browser-followup-" + operation
        old = self.journal.data["incoming"].get(key)
        if old:
            if old.get("body") != body:
                raise Unavailable("Duplicate reply changed payload")
            if old.get("status") == "done":
                return old.get("result") or {"status": "uncertain"}
            receipt = await self.call_browser({"action": "followupReceipt", "principal": principal, "operationID": operation})
            return self.record_browser_receipt(key, receipt)
        self.journal.commit(lambda d: d["incoming"].__setitem__(key, {"status": "sending", "body": body}))
        try:
            result = await self.call_browser(body)
            return self.record_browser_receipt(key, result)
        except Denied:
            self.journal.commit(lambda d: d["incoming"][key].update(status="uncertain"))
            raise
        except (Exception, asyncio.CancelledError) as error:
            self.journal.commit(lambda d: d["incoming"][key].update(status="uncertain"))
            if isinstance(error, asyncio.CancelledError):
                raise
            receipt = await self.call_browser({"action": "followupReceipt", "principal": principal, "operationID": operation})
            return self.record_browser_receipt(key, receipt)

    async def post_browser_page(self, principal, body, away_guard=None):
        await self.check_away(principal, away_guard)
        request = {"action": "boundContext", "principal": principal, "sessionID": body["sessionID"],
                   "identity": body["identity"], "slackThread": body["slackThread"], "limit": 3}
        if body.get("cursor"):
            request["cursor"] = body["cursor"]
        if body.get("terminalOutput"):
            request["terminalOutput"] = True
        context = await self.call_browser(request)
        pieces = []
        for message in context.get("messages", []):
            body_text = message["text"]
            # Swift's character limit counts grapheme clusters, while Slack's
            # limit counts code points. Pathological clusters can therefore
            # exceed the presentation bound even after the reader's cap.
            if len(body_text) > 8000:
                body_text = body_text[:8000] + "\n[Message truncated in Slack]"
            pieces.append(f"{message['role'].capitalize()}: {body_text}")
        if context.get("output"):
            pieces.append(context["output"])
        text = "\n\n".join(pieces) or "No readable messages in this page."
        # The local reader caps each message at 8,000 characters. Three
        # messages fit comfortably within Slack's 50-block limit even when
        # each section is split at Slack's text limit. Never advance a history
        # cursor past messages hidden by presentation truncation.
        if body.get("terminalOutput") and len(text) > 100_000:
            text = text[-100_000:]
            text = "[Older terminal output truncated in Slack]\n" + text
        label = f"Source: {context.get('source', 'unavailable')}"
        if context.get("truncated"):
            label += " · history truncated"
        if context.get("mayBeStale"):
            label += " · may be stale"
        if context.get("limitation"):
            label += "\n" + context["limitation"]
        blocks = [section(label)] + [section(text[i:i + 2900]) for i in range(0, len(text), 2900)]
        controls = []
        if context.get("earlier"):
            controls.append(self.browser_button("Earlier messages", {**body, "cursor": context["earlier"], "terminalOutput": False}, principal))
        controls.append(self.browser_button("Latest", {**body, "cursor": None, "terminalOutput": False}, principal))
        if body["identity"].get("kind") in ("terminalCodex", "terminalPane"):
            controls.append(self.browser_button("Terminal output", {**body, "cursor": None, "terminalOutput": True}, principal))
        blocks.append({"type": "actions", "elements": controls})
        guard = {"sessionID": body["sessionID"], "identity": body["identity"], "slackThread": body["slackThread"]}
        key = "browser-page-" + stable_id(principal["workspace"], principal["channel"], guard, body.get("cursor"), body.get("terminalOutput"), context)
        await self.post_once(key, principal, body["slackThread"], label + "\n" + text[:2400], blocks,
                             browser_binding=guard, away_guard=away_guard)
        if body["identity"].get("kind") in ("terminalCodex", "puck") and not body.get("cursor") and not body.get("terminalOutput"):
            await self.render_terminal_decision(principal, guard, away_guard=away_guard)

    async def answer_browser(self, principal, body, operation):
        await self.check(principal)
        request = {"action": "answer", "principal": principal, "sessionID": body["sessionID"],
                   "identity": body["identity"], "slackThread": body["slackThread"],
                   "requestID": body["requestID"], "option": body["option"], "operationID": operation}
        if "selections" in body:
            request["selections"] = body["selections"]
        key = "browser-answer-" + operation
        old = self.journal.data["incoming"].get(key)
        if old:
            if old.get("body") != request:
                raise Unavailable("Duplicate answer changed payload")
            if old.get("status") == "done":
                return old.get("result") or {"status": "uncertain"}
            receipt = await self.call_browser({"action": "decisionReceipt", "principal": principal, "operationID": operation})
            return self.record_browser_receipt(key, receipt)
        self.journal.commit(lambda d: d["incoming"].__setitem__(key, {"status": "sending", "body": request}))
        try:
            result = await self.call_browser(request)
            return self.record_browser_receipt(key, result)
        except Denied:
            self.journal.commit(lambda d: d["incoming"][key].update(status="uncertain"))
            raise
        except (Exception, asyncio.CancelledError) as error:
            self.journal.commit(lambda d: d["incoming"][key].update(status="uncertain"))
            if isinstance(error, asyncio.CancelledError):
                raise
            receipt = await self.call_browser({"action": "decisionReceipt", "principal": principal, "operationID": operation})
            return self.record_browser_receipt(key, receipt)

    def terminal_decision_blocks(self, principal, binding, decision):
        if not decision.get("answerable") or decision.get("status") != "pending":
            return [section("Decision resolved or unavailable. No answer controls are active.")]
        if decision.get("kind") == "puckQuestion":
            questions = decision.get("questions", [])
            if not questions or len(questions) > 12:
                return [section("This decision cannot be displayed safely. Answer it on the Mac.")]
            blocks = []
            for question in questions:
                text = str(question.get("question", ""))
                options = question.get("options", [])
                choices = "\n".join(f"• {item.get('label', '')}: {item.get('description', '')}" for item in options)
                if not text or len(text) > 2800 or len(choices) > 2800:
                    return [section("This decision is too large to display safely in Slack. Answer it on the Mac.")]
                blocks.append(section(text))
                if choices:
                    blocks.append(section(choices))
            recent = "\n".join(f"{m.get('role', 'message')}: {m.get('text', '')}" for m in decision.get("recentContext", [])[-3:])
            if recent:
                blocks.append(section("Recent context:\n" + recent[-2000:]))
            controls = [self.browser_button("Answer questions", {"action": "puck_question", **binding,
                "requestID": decision["requestID"]}, principal),
                self.browser_button("Read more", {"action": "browser_page", **binding,
                    "cursor": None, "terminalOutput": False}, principal)]
            blocks.append({"type": "actions", "elements": controls})
            return blocks
        question, options = decision.get("question", ""), decision.get("options", [])
        if not question or len(question) > 2800 or not options or len(options) > 24 or any(len(str(o.get("label", ""))) > 2800 for o in options):
            return [section("This decision is too large to display safely in Slack. Answer it on the Mac.")]
        blocks = [section(question)]
        preceding = "\n".join(str(v) for v in decision.get("context", []))
        recent = "\n".join(f"{m.get('role', 'message')}: {m.get('text', '')}" for m in decision.get("recentContext", [])[-3:])
        context = "\n".join(v for v in (preceding, recent) if v)
        if context:
            if len(context) > 2600:
                context = context[-2600:] + "\n[Context truncated]"
            blocks.append(section("Recent context\n" + context))
        buttons = []
        for option in options:
            index, label = option.get("index"), option.get("label", "")
            if not isinstance(index, int) or index <= 0 or not label:
                return [section("This decision cannot be displayed safely. Answer it on the Mac.")]
            blocks.append(section(f"{index}. {label}"))
            buttons.append(self.browser_button(str(index), {"action": "browser_answer", **binding,
                "requestID": decision["requestID"], "option": index}, principal))
        buttons.append(self.browser_button("Read more", {"action": "browser_page", **binding,
            "cursor": None, "terminalOutput": False}, principal))
        blocks.append({"type": "actions", "elements": buttons})
        return blocks

    async def render_terminal_decision(self, principal, binding, away_guard=None):
        await self.check_away(principal, away_guard)
        request = {"action": "decision", "principal": principal, **binding}
        decision = await self.call_browser(request)
        key = "browser-decision-" + stable_id(principal["workspace"], principal["channel"], binding)
        title = "Puck decision" if binding["identity"].get("kind") == "puck" else "Terminal decision"
        existing = self.journal.data["posts"].get(key, {})
        active = decision.get("status") == "pending" and decision.get("answerable")
        if not active and not existing.get("ts"):
            return
        blocks = self.terminal_decision_blocks(principal, binding, decision)
        if active:
            guard = {**binding, "requestID": decision["requestID"]}
            try:
                ts = await self.post_once(key, principal, binding["slackThread"], title, blocks,
                                          browser_binding=guard, away_guard=away_guard)
            except StaleBrowser:
                decision = await self.call_browser(request)
                blocks = self.terminal_decision_blocks(principal, binding, decision)
                ts = existing.get("ts")
        else:
            ts = existing.get("ts")
        if not ts:
            return
        # Refresh once more immediately before publishing controls. If the Mac
        # resolved the question, remove them instead of posting stale choices.
        latest = await self.call_browser(request)
        if latest.get("requestID") != decision.get("requestID") or latest.get("status") != decision.get("status"):
            decision = latest
            blocks = self.terminal_decision_blocks(principal, binding, decision)
        guard = dict(binding)
        if decision.get("status") == "pending" and decision.get("answerable"):
            guard["requestID"] = decision["requestID"]
        try:
            await self.check_browser(principal, guard)
        except StaleBrowser:
            await self.check_browser(principal, binding)
            blocks = [section("Decision resolved or unavailable. No answer controls are active.")]
        await self.check_away(principal, away_guard)
        await self.slack.call("chat.update", channel=principal["channel"], ts=ts,
                              text=title, blocks=blocks[:50], parse="none")
        self.journal.commit(lambda d: d["posts"][key].update(browser_binding=guard))

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
