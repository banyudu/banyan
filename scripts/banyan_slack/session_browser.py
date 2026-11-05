"""Session browsing and bound-thread decisions using the connector state."""
import asyncio
import unicodedata

from .connector_state import Denied, StaleBrowser, Unavailable, plain, section, stable_id


class SessionBrowserMixin:
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
