#!/usr/bin/env python3
"""Disposable App Home and thread fixtures; no Slack SDK or live services."""
import asyncio
import copy
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from banyan_slack.connector import Connector, Denied, Unavailable
from test_slack_connector import FakeAPI, FakeSlack, PRINCIPAL


class BrowserAPI(FakeAPI):
    def __init__(self):
        super().__init__()
        self.browser_calls = []
        self.mappings = {}
        self.generations = {}
        self.fallback = False
        self.bind_response_lost = False
        self.pending = False
        self.request_id = "request-a"
        self.decision_calls = 0
        self.resolve_on_decision_call = None
        self.answers = []
        self.receipts = {}
        self.lose_answer_response = False
        self.replies = []
        self.reply_status = "submitted"
        self.lose_reply_response = False
        self.away = {"enabled": False, "sessionIDs": [], "projectIDs": [], "activationID": None, "revision": 0}
        self.away_epoch = "epoch-a"
        self.away_cursor = 0
        self.away_events = []
        self.away_snapshot_calls = 0
        self.resolve_on_snapshot_call = None
        self.away_gap = False
        self.rows = [{"sessionID": f"row-{i}", "title": f"Session {i}", "project": "Alpha" if i < 13 else "Beta",
                      "projectID": "alpha" if i < 13 else "beta",
                      "status": "asking" if i == 0 else "executing", "backend": "terminal", "needsAttention": i == 0}
                     for i in range(25)]

    def identity(self, session_id):
        if self.fallback:
            return {"kind": "terminalPane", "conversationID": "%1", "generation": "100:1:0"}
        return {"kind": "terminalCodex", "conversationID": "thread-" + session_id,
                "generation": self.generations.get(session_id, "generation-a")}

    async def browser(self, body):
        self.browser_calls.append(copy.deepcopy(body))
        if not self.allowed:
            raise Denied("Denied")
        action = body["action"]
        if action in ("decisionReceipt", "followupReceipt"):
            return copy.deepcopy(self.receipts.get(body["operationID"], {"status": "absent"}))
        if action == "awayStatus":
            return copy.deepcopy(self.away)
        if action == "awayConfigure":
            previous = copy.deepcopy(self.away)
            for field, key in (("followSessionID", "sessionIDs"), ("followProjectID", "projectIDs")):
                if field in body:
                    value = body[field]
                    if body.get("follow") and value not in self.away[key]:
                        self.away[key].append(value)
                    elif not body.get("follow") and value in self.away[key]:
                        self.away[key].remove(value)
            if "awayEnabled" in body:
                self.away["enabled"] = body["awayEnabled"]
            if self.away != previous:
                self.away["revision"] += 1
                if self.away["enabled"]:
                    self.away["activationID"] = "activation-" + str(self.away["revision"])
            return copy.deepcopy(self.away)
        if action == "awayEvents":
            cursor = body.get("eventCursor")
            same = (body.get("eventEpoch") == self.away_epoch and
                    body.get("awayActivationID") == self.away["activationID"] and
                    body.get("awayRevision") == self.away["revision"] and cursor is not None)
            return {"enabled": self.away["enabled"], "activationID": self.away["activationID"],
                    "revision": self.away["revision"], "epoch": self.away_epoch, "cursor": self.away_cursor,
                    "gap": self.away_gap, "refresh": self.away["enabled"] and (not same or self.away_gap),
                    "events": [copy.deepcopy(e) for e in self.away_events if same and e["cursor"] > cursor]}
        if action == "awaySnapshot":
            self.away_snapshot_calls += 1
            if self.resolve_on_snapshot_call == self.away_snapshot_calls:
                self.pending = False
            rows = [copy.deepcopy(r) for r in self.rows if r["sessionID"] in self.away["sessionIDs"] or r["projectID"] in self.away["projectIDs"]]
            decisions = [{"sessionID": "row-0", "question": "Do you want to proceed?", "options": [
                {"index": 1, "label": "Yes"}, {"index": 2, "label": "No"}]}] if self.pending and any(r["sessionID"] == "row-0" for r in rows) else []
            return {"activationID": self.away["activationID"], "revision": self.away["revision"], "epoch": self.away_epoch,
                    "cursor": self.away_cursor, "gap": self.away_gap, "sessions": rows, "decisions": decisions,
                    "events": copy.deepcopy(self.away_events)}
        if action == "awaySession":
            row = next((r for r in self.rows if r["sessionID"] == body["sessionID"]), None)
            if not row or not self.away["enabled"] or (row["sessionID"] not in self.away["sessionIDs"] and row["projectID"] not in self.away["projectIDs"]):
                raise Unavailable("Outside Away scope")
            return {**copy.deepcopy(row), "pending": self.pending and row["sessionID"] == "row-0",
                    "question": "Do you want to proceed?" if self.pending and row["sessionID"] == "row-0" else None,
                    "activationID": self.away["activationID"], "revision": self.away["revision"]}
        if action == "awayCheck":
            session = next((r for r in self.rows if r["sessionID"] == body.get("sessionID")), None)
            allowed = self.away["enabled"] and (body.get("sessionID") is None or bool(session and (
                session["sessionID"] in self.away["sessionIDs"] or session["projectID"] in self.away["projectIDs"])))
            return {"allowed": allowed, "activationID": self.away["activationID"], "revision": self.away["revision"]}
        if action == "list":
            query = body.get("query", "").lower()
            rows = [r for r in self.rows if query in (r["title"] + r["project"] + r["sessionID"]).lower()]
            if body.get("filter") == "needs":
                rows = [r for r in rows if r["needsAttention"]]
            if body.get("filter") == "working":
                rows = [r for r in rows if r["status"] == "executing"]
            start, limit = body.get("offset", 0), body.get("limit", 10)
            return {"sessions": copy.deepcopy(rows[start:start + limit]),
                    "nextOffset": start + limit if start + limit < len(rows) else None, "total": len(rows)}
        session_id = body["sessionID"]
        identity = self.identity(session_id)
        key = (session_id, json.dumps(identity, sort_keys=True))
        context = {"source": "providerTranscript", "conversationID": identity["conversationID"], "binding": identity,
                   "messages": [{"role": "user", "text": "before away", "truncated": False}],
                   "earlier": "previous-page", "output": None, "limitation": None, "truncated": False, "mayBeStale": False}
        if self.fallback:
            context.update(source="terminalOutput", messages=[], earlier=None, output="retained terminal output",
                           limitation="History unavailable. Replies are disabled without an exact conversation identity.",
                           truncated=True, mayBeStale=True)
        if action == "open":
            return {"binding": identity, "attachment": copy.deepcopy(self.mappings.get(key)), "context": context}
        if action == "bind":
            if body["identity"] != identity:
                raise Unavailable("Changed")
            root = body["slackThread"]
            if key in self.mappings and self.mappings[key]["slackThread"] != root:
                raise Unavailable("Conflict")
            if any(v["slackThread"] == root and k != key for k, v in self.mappings.items()):
                raise Unavailable("Conflict")
            self.mappings[key] = {"id": "attachment-" + session_id, "sessionID": session_id,
                                  "workspace": "T_TEST", "channel": "C_TEST", "slackThread": root}
            if self.bind_response_lost:
                self.bind_response_lost = False
                raise Unavailable("Lost bind response")
            return {"binding": identity, "attachment": copy.deepcopy(self.mappings[key]), "context": context}
        if action == "decision":
            attachment = self.mappings.get(key) or {}
            if body["identity"] != identity or attachment.get("slackThread") != body["slackThread"]:
                raise Unavailable("Changed")
            self.decision_calls += 1
            if self.resolve_on_decision_call == self.decision_calls:
                self.pending = False
            if not self.pending:
                return {"status": "resolved", "requestID": None, "options": [], "answerable": False}
            return {"status": "pending", "requestID": self.request_id, "question": "Do you want to proceed?",
                    "context": ["echo fixture"], "recentContext": [{"role": "user", "text": "before away"}],
                    "options": [{"index": 1, "label": "Yes"}, {"index": 2, "label": "No"}], "answerable": True}
        if action == "followup":
            attachment = self.mappings.get(key) or {}
            if body["identity"] != identity or attachment.get("slackThread") != body["slackThread"]:
                raise Unavailable("Changed")
            if self.reply_status != "rejected":
                self.replies.append(body["text"])
            result = {"status": self.reply_status}
            if self.reply_status == "rejected":
                result["reason"] = "busy_or_unavailable"
            if self.reply_status == "uncertain":
                result["reason"] = "delivery_outcome_unknown"
            self.receipts[body["operationID"]] = result
            if self.lose_reply_response:
                self.lose_reply_response = False
                raise Unavailable("Lost reply response")
            return copy.deepcopy(result)
        if action == "answer":
            attachment = self.mappings.get(key) or {}
            if body["identity"] != identity or attachment.get("slackThread") != body["slackThread"] or not self.pending or body["requestID"] != self.request_id:
                raise Unavailable("Stale request")
            self.answers.append(body["option"])
            self.pending = False
            self.receipts[body["operationID"]] = {"status": "submitted", "operationID": body["operationID"]}
            if self.lose_answer_response:
                self.lose_answer_response = False
                raise Unavailable("Lost answer response")
            return {"status": "submitted"}
        if action == "boundContext":
            attachment = self.mappings.get(key) or {}
            if body["identity"] != identity or attachment.get("slackThread") != body["slackThread"]:
                raise Unavailable("Changed")
            if body.get("cursor"):
                context["messages"] = [{"role": "assistant", "text": "older context", "truncated": False}]
                context["earlier"] = None
            if body.get("terminalOutput"):
                context.update(source="terminalOutput", messages=[], output="retained output", limitation="History limited", mayBeStale=True)
            return context
        raise AssertionError(action)


def home_event(user="U_TEST", workspace="T_TEST"):
    return {"envelope_id": "home-event", "type": "events_api", "payload": {"team_id": workspace,
            "event": {"type": "app_home_opened", "tab": "home", "user": user}}}


def interaction(action_id, value, user="U_TEST", channel=None, view=None):
    payload = {"type": "block_actions", "team": {"id": "T_TEST"}, "user": {"id": user},
               "actions": [{"action_id": action_id, "value": value, "action_ts": "20.1"}]}
    if channel:
        payload["channel"] = {"id": channel}
    if view:
        payload["view"] = view
    return {"envelope_id": "action-event", "type": "interactive", "payload": payload}


class BrowserTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="banyan-browser-test-")
        self.path = Path(self.tmp.name) / "state.json"
        self.api, self.slack = BrowserAPI(), FakeSlack()
        self.connector = Connector(self.api, self.slack, self.path, [PRINCIPAL], "BOT", post_interval=0)
        self.acks = []

    async def asyncTearDown(self):
        self.tmp.cleanup()

    async def ack(self, eid):
        self.acks.append(eid)

    def last_home(self):
        return [fields["view"] for method, fields in self.slack.calls if method == "views.publish"][-1]

    def home_open_button(self):
        return next(block["accessory"] for block in self.last_home()["blocks"] if "accessory" in block)

    async def test_home_filters_search_pagination_and_exact_user_authorization(self):
        await self.connector.envelope(home_event("U_OTHER"), self.ack)
        self.assertEqual(self.api.browser_calls, [])
        await self.connector.envelope(home_event(), self.ack)
        view = self.last_home()
        rows = [block for block in view["blocks"] if "accessory" in block]
        self.assertEqual(len(rows), 10)
        self.assertTrue(any(block.get("text", {}).get("text") == "Alpha" for block in view["blocks"]))
        self.assertFalse(any(method == "chat.postMessage" for method, _ in self.slack.calls))
        next_button = next(e for block in view["blocks"] if block.get("type") == "actions"
                           for e in block["elements"] if e["text"]["text"] == "Next")
        await self.connector.envelope(interaction("banyan_home", next_button["value"], view=view), self.ack)
        self.assertEqual([c for c in self.api.browser_calls if c["action"] == "list"][-1]["offset"], 10)
        view = self.last_home()
        await self.connector.envelope(interaction("banyan_home_search", "Beta", view=view), self.ack)
        self.assertEqual([c for c in self.api.browser_calls if c["action"] == "list"][-1]["query"], "Beta")
        view = self.last_home()
        needs = next(e for block in view["blocks"] if block.get("type") == "actions"
                     for e in block["elements"] if e["text"]["text"] == "Needs you")
        await self.connector.envelope(interaction("banyan_home", needs["value"], view=view), self.ack)
        self.assertEqual([c for c in self.api.browser_calls if c["action"] == "list"][-1]["filter"], "needs")
        before = len(self.slack.calls)
        await self.connector.envelope(interaction("banyan_home", needs["value"], user="U_OTHER", view=view), self.ack)
        self.assertEqual(len(self.slack.calls), before)

    async def test_away_catchup_delivers_existing_pending_once_and_off_suppresses_events(self):
        self.api.away.update(enabled=True, sessionIDs=["row-0"], activationID="activation-a", revision=1)
        self.api.pending = True
        self.api.away_cursor = 1
        self.api.away_events = [{"cursor": 1, "sessionID": "row-0", "status": "asking"}]
        await self.connector.refresh_away(PRINCIPAL)
        posts = [fields for method, fields in self.slack.calls if method == "chat.postMessage"]
        digest = [p for p in posts if p["text"].startswith("Away catch-up")]
        self.assertEqual(len(digest), 1)
        self.assertIn("Do you want to proceed?", digest[0]["text"])
        self.assertEqual(len([p for p in posts if p["text"] == "Terminal decision"]), 1)
        self.assertEqual(len(self.connector.journal.data["awaySeen"]), 1)
        count = len(posts)
        await self.connector.refresh_away(PRINCIPAL)
        self.assertEqual(len([1 for method, _ in self.slack.calls if method == "chat.postMessage"]), count)
        self.api.away.update(enabled=False, revision=2)
        self.api.away_cursor = 2
        self.api.away_events.append({"cursor": 2, "sessionID": "row-0", "status": "completed"})
        await self.connector.refresh_away(PRINCIPAL)
        self.assertEqual(len([1 for method, _ in self.slack.calls if method == "chat.postMessage"]), count)
        # Authorized Home browsing remains available with Away off.
        await self.connector.envelope(home_event(), self.ack)
        self.assertTrue(any(method == "views.publish" for method, _ in self.slack.calls))

    async def test_new_decision_notifies_once_and_desktop_resolution_removes_controls(self):
        self.api.away.update(enabled=True, sessionIDs=["row-0"], activationID="activation-a", revision=1)
        self.api.pending = True
        self.api.away_cursor = 1
        self.api.away_events = [{"cursor": 1, "sessionID": "row-0", "status": "asking"}]
        await self.connector.refresh_away(PRINCIPAL)
        self.api.request_id = "request-b"
        self.api.away_cursor = 2
        self.api.away_events.append({"cursor": 2, "sessionID": "row-0", "status": "asking"})
        await self.connector.refresh_away(PRINCIPAL)
        posts = [f for m, f in self.slack.calls if m == "chat.postMessage"]
        self.assertEqual(len([p for p in posts if p["text"] == "A new decision needs your attention."]), 1)
        self.api.away_cursor = 3
        self.api.away_events.append({"cursor": 3, "sessionID": "row-0", "status": "asking"})
        await self.connector.refresh_away(PRINCIPAL)
        posts = [f for m, f in self.slack.calls if m == "chat.postMessage"]
        self.assertEqual(len([p for p in posts if p["text"] == "A new decision needs your attention."]), 1)
        self.api.pending = False
        self.api.rows[0]["status"] = "executing"
        self.api.away_cursor = 4
        self.api.away_events.append({"cursor": 4, "sessionID": "row-0", "status": "executing"})
        await self.connector.refresh_away(PRINCIPAL)
        updates = [f for m, f in self.slack.calls if m == "chat.update"]
        self.assertTrue(updates)
        self.assertFalse(any(block.get("type") == "actions" for block in updates[-1]["blocks"]))

    async def test_restart_epoch_gap_reports_once_without_repeating_digest(self):
        self.api.away.update(enabled=True, sessionIDs=["row-0"], activationID="activation-a", revision=1)
        self.api.pending = True
        await self.connector.refresh_away(PRINCIPAL)
        restarted = Connector(self.api, self.slack, self.path, [PRINCIPAL], "BOT", post_interval=0)
        self.api.away_epoch = "epoch-b"
        self.api.away_gap = True
        await restarted.refresh_away(PRINCIPAL)
        posts = [f for m, f in self.slack.calls if m == "chat.postMessage"]
        self.assertEqual(len([p for p in posts if p["text"].startswith("Away catch-up")]), 1)
        self.assertEqual(len([p for p in posts if "could not be recovered" in p["text"]]), 1)
        await restarted.refresh_away(PRINCIPAL)
        posts = [f for m, f in self.slack.calls if m == "chat.postMessage"]
        self.assertEqual(len([p for p in posts if "could not be recovered" in p["text"]]), 1)

    async def test_resolved_catchup_rechecks_before_delivery(self):
        from banyan_slack.connector import StaleAway
        self.api.away.update(enabled=True, sessionIDs=["row-0"], activationID="activation-a", revision=1)
        self.api.pending = True
        self.api.resolve_on_snapshot_call = 2
        with self.assertRaises(StaleAway):
            await self.connector.refresh_away(PRINCIPAL)
        self.assertFalse(any(method == "chat.postMessage" for method, _ in self.slack.calls))
        await self.connector.refresh_away(PRINCIPAL)
        posts = [fields for method, fields in self.slack.calls if method == "chat.postMessage"]
        self.assertEqual(len([p for p in posts if p["text"].startswith("Away catch-up")]), 1)
        self.assertFalse(any(p["text"] == "Terminal decision" for p in posts))

    async def test_away_disable_during_rate_limit_cancels_the_retry(self):
        from banyan_slack.connector import StaleAway
        self.api.away.update(enabled=True, sessionIDs=["row-0"], activationID="activation-a", revision=1)
        self.slack.rate_rejections = 1
        self.slack.retry_after = 0.05
        running = asyncio.create_task(self.connector.refresh_away(PRINCIPAL))
        await asyncio.wait_for(self.slack.rate_seen.wait(), 1)
        self.api.away.update(enabled=False, revision=2)
        with self.assertRaises(StaleAway):
            await running
        self.assertEqual(self.slack.posts, 1)
        digest = [v for k, v in self.connector.journal.data["posts"].items() if k.startswith("away-digest-")]
        self.assertEqual([v["status"] for v in digest], ["cancelled"])

    async def test_home_follow_scope_and_away_toggle_are_explicit(self):
        await self.connector.envelope(home_event(), self.ack)
        view = self.last_home()
        toggle = next(e for b in view["blocks"] if b.get("type") == "actions" for e in b["elements"] if e["text"]["text"] == "Turn Away on")
        await self.connector.envelope(interaction("banyan_home", toggle["value"], view=view), self.ack)
        self.assertFalse(self.api.away["enabled"])
        self.assertTrue(any("Follow a session" in b.get("text", {}).get("text", "") for b in self.last_home()["blocks"]))
        view = self.last_home()
        follow = next(e for b in view["blocks"] if b.get("type") == "actions" for e in b["elements"] if e["text"]["text"] == "Follow")
        await self.connector.envelope(interaction("banyan_home", follow["value"], view=view), self.ack)
        self.assertEqual(self.api.away["sessionIDs"], ["row-0"])
        view = self.last_home()
        toggle = next(e for b in view["blocks"] if b.get("type") == "actions" for e in b["elements"] if e["text"]["text"] == "Turn Away on")
        await self.connector.envelope(interaction("banyan_home", toggle["value"], view=view), self.ack)
        self.assertTrue(self.api.away["enabled"])
        view = self.last_home()
        toggle = next(e for b in view["blocks"] if b.get("type") == "actions" for e in b["elements"] if e["text"]["text"] == "Turn Away off")
        await self.connector.envelope(interaction("banyan_home", toggle["value"], view=view), self.ack)
        self.assertFalse(self.api.away["enabled"])
        self.assertEqual(self.api.away["sessionIDs"], ["row-0"])

    async def test_open_reuses_thread_and_navigation_is_bound_to_conversation(self):
        await self.connector.envelope(home_event(), self.ack)
        button = self.home_open_button()
        action = interaction("banyan_home", button["value"], view=self.last_home())
        await self.connector.envelope(action, self.ack)
        posts = [fields for method, fields in self.slack.calls if method == "chat.postMessage"]
        self.assertEqual(len(posts), 2)
        self.assertNotIn("thread_ts", posts[0])
        self.assertIn("Session: row-0", posts[0]["text"])
        self.assertEqual(posts[1]["thread_ts"], "200.1")
        self.assertIn("before away", posts[1]["text"])
        await self.connector.envelope(action, self.ack)
        self.assertEqual(len([1 for method, _ in self.slack.calls if method == "chat.postMessage"]), 2)
        earlier = next(e for block in posts[1]["blocks"] if block.get("type") == "actions"
                       for e in block["elements"] if e["text"]["text"] == "Earlier messages")
        await self.connector.envelope(interaction("banyan_browser", earlier["value"], channel="C_TEST"), self.ack)
        posts = [fields for method, fields in self.slack.calls if method == "chat.postMessage"]
        self.assertEqual(len(posts), 3)
        self.assertEqual(posts[-1]["thread_ts"], "200.1")
        self.assertIn("older context", posts[-1]["text"])
        self.api.generations["row-0"] = "generation-b"
        await self.connector.envelope(interaction("banyan_browser", earlier["value"], channel="C_TEST"), self.ack)
        self.assertEqual(len([1 for method, _ in self.slack.calls if method == "chat.postMessage"]), 3)

    async def test_pending_decision_has_exact_choices_and_duplicate_answer_is_not_replayed(self):
        self.api.pending = True
        await self.connector.envelope(home_event(), self.ack)
        action = interaction("banyan_home", self.home_open_button()["value"], view=self.last_home())
        await self.connector.envelope(action, self.ack)
        posts = [fields for method, fields in self.slack.calls if method == "chat.postMessage"]
        card = next(p for p in posts if p["text"] == "Terminal decision")
        labels = [b.get("text", {}).get("text", "") for b in card["blocks"]]
        self.assertIn("Do you want to proceed?", labels)
        self.assertIn("1. Yes", labels)
        self.assertIn("2. No", labels)
        self.assertTrue(any("echo fixture" in text and "before away" in text for text in labels))
        option = next(e for b in card["blocks"] if b.get("type") == "actions"
                      for e in b["elements"] if e["text"]["text"] == "2")
        clicked = interaction("banyan_browser", option["value"], channel="C_TEST")
        await self.connector.envelope(clicked, self.ack)
        await self.connector.envelope(clicked, self.ack)
        self.assertEqual(self.api.answers, [2])
        updates = [fields for method, fields in self.slack.calls if method == "chat.update"]
        self.assertTrue(updates)
        self.assertFalse(any(b.get("type") == "actions" for b in updates[-1]["blocks"]))

    async def test_decision_resolved_before_delivery_has_no_actionable_card(self):
        self.api.pending = True
        self.api.resolve_on_decision_call = 2
        await self.connector.envelope(home_event(), self.ack)
        await self.connector.envelope(interaction("banyan_home", self.home_open_button()["value"], view=self.last_home()), self.ack)
        cards = [fields for method, fields in self.slack.calls if method == "chat.postMessage" and fields["text"] == "Terminal decision"]
        self.assertEqual(cards, [])
        self.assertEqual(self.api.answers, [])

    async def test_lost_answer_response_reconciles_receipt_without_resubmission(self):
        self.api.pending = True
        self.api.lose_answer_response = True
        await self.connector.envelope(home_event(), self.ack)
        await self.connector.envelope(interaction("banyan_home", self.home_open_button()["value"], view=self.last_home()), self.ack)
        card = next(fields for method, fields in self.slack.calls if method == "chat.postMessage" and fields["text"] == "Terminal decision")
        option = next(e for b in card["blocks"] if b.get("type") == "actions" for e in b["elements"] if e["text"]["text"] == "1")
        clicked = interaction("banyan_browser", option["value"], channel="C_TEST")
        await self.connector.envelope(clicked, self.ack)
        await self.connector.envelope(clicked, self.ack)
        self.assertEqual(self.api.answers, [1])
        self.assertEqual(len([c for c in self.api.browser_calls if c["action"] == "answer"]), 1)
        self.assertTrue(any(c["action"] == "decisionReceipt" for c in self.api.browser_calls))

    async def test_ambiguous_history_shows_read_only_terminal_output(self):
        self.api.fallback = True
        await self.connector.envelope(home_event(), self.ack)
        await self.connector.envelope(interaction("banyan_home", self.home_open_button()["value"], view=self.last_home()), self.ack)
        posts = [fields for method, fields in self.slack.calls if method == "chat.postMessage"]
        self.assertEqual(len(posts), 2)
        self.assertIn("retained terminal output", posts[1]["text"])
        self.assertIn("Replies are disabled", posts[1]["text"])
        reply = {"envelope_id": "reply", "type": "events_api", "payload": {"team_id": "T_TEST", "event": {
            "type": "message", "user": "U_TEST", "channel": "C_TEST", "ts": "200.9", "thread_ts": "200.1", "text": "continue"}}}
        await self.connector.envelope(reply, self.ack)
        self.assertFalse(any(call["action"] == "followup" for call in self.api.browser_calls))
        self.assertIn("exact conversation identity is unavailable", [fields for method, fields in self.slack.calls if method == "chat.postMessage"][-1]["text"])

    async def test_terminal_reply_is_sent_once_and_receipted(self):
        await self.connector.envelope(home_event(), self.ack)
        action = interaction("banyan_home", self.home_open_button()["value"], view=self.last_home())
        await self.connector.envelope(action, self.ack)
        reply = {"envelope_id": "reply", "type": "events_api", "payload": {"team_id": "T_TEST", "event": {
            "type": "message", "user": "U_TEST", "channel": "C_TEST", "ts": "200.9", "thread_ts": "200.1", "text": "continue"}}}
        await self.connector.envelope(reply, self.ack)
        posts = [fields for method, fields in self.slack.calls if method == "chat.postMessage"]
        self.assertIn("Reply submitted", posts[-1]["text"])
        self.assertEqual(posts[-1]["thread_ts"], "200.1")
        await self.connector.envelope(reply, self.ack)
        self.assertEqual(self.api.replies, ["continue"])
        self.assertEqual(len([1 for method, _ in self.slack.calls if method == "chat.postMessage"]), len(posts))

    async def test_puck_multiline_reply_is_sent_once_to_its_binding(self):
        self.api.rows[0]["backend"] = "puck"
        self.api.identity = lambda session_id: {"kind": "puck", "conversationID": session_id, "generation": "puck"}
        await self.connector.envelope(home_event(), self.ack)
        await self.connector.envelope(interaction("banyan_home", self.home_open_button()["value"], view=self.last_home()), self.ack)
        reply = {"envelope_id": "puck-reply", "type": "events_api", "payload": {"team_id": "T_TEST", "event": {
            "type": "message", "user": "U_TEST", "channel": "C_TEST", "ts": "200.9", "thread_ts": "200.1", "text": "first\nsecond"}}}
        await self.connector.envelope(reply, self.ack)
        await self.connector.envelope(reply, self.ack)
        self.assertEqual(self.api.replies, ["first\nsecond"])
        calls = [call for call in self.api.browser_calls if call["action"] == "followup"]
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0]["identity"]["kind"], "puck")
        self.assertEqual(calls[0]["sessionID"], "row-0")

    async def test_history_page_displays_all_messages_before_advancing_cursor(self):
        original = self.api.browser
        messages = ["A" * 8000, "B" * 8000, "C" * 8000]

        async def browser(body):
            result = await original(body)
            if body["action"] == "boundContext":
                result["messages"] = [{"role": "user", "text": value, "truncated": False} for value in messages]
            return result

        self.api.browser = browser
        await self.connector.envelope(home_event(), self.ack)
        await self.connector.envelope(interaction("banyan_home", self.home_open_button()["value"], view=self.last_home()), self.ack)
        page = [fields for method, fields in self.slack.calls if method == "chat.postMessage"][-1]
        displayed = "".join(block["text"]["text"] for block in page["blocks"] if block["type"] == "section")
        for message in messages:
            self.assertIn(message, displayed)
        self.assertLessEqual(len(page["blocks"]), 50)
        self.assertEqual(next(c for c in self.api.browser_calls if c["action"] == "boundContext")["limit"], 3)

    async def test_history_page_marks_presentation_truncation(self):
        original = self.api.browser

        async def browser(body):
            result = await original(body)
            if body["action"] == "boundContext":
                result["messages"] = [{"role": "user", "text": "e\u0301" * 9000, "truncated": False}]
            return result

        self.api.browser = browser
        await self.connector.envelope(home_event(), self.ack)
        await self.connector.envelope(interaction("banyan_home", self.home_open_button()["value"], view=self.last_home()), self.ack)
        page = [fields for method, fields in self.slack.calls if method == "chat.postMessage"][-1]
        displayed = "".join(block["text"]["text"] for block in page["blocks"] if block["type"] == "section")
        self.assertIn("[Message truncated in Slack]", displayed)
        self.assertLessEqual(len(page["blocks"]), 50)

    async def test_busy_and_uncertain_replies_are_not_retried(self):
        await self.connector.envelope(home_event(), self.ack)
        await self.connector.envelope(interaction("banyan_home", self.home_open_button()["value"], view=self.last_home()), self.ack)
        def reply(ts, text):
            return {"envelope_id": ts, "type": "events_api", "payload": {"team_id": "T_TEST", "event": {
                "type": "message", "user": "U_TEST", "channel": "C_TEST", "ts": ts, "thread_ts": "200.1", "text": text}}}
        self.api.reply_status = "rejected"
        await self.connector.envelope(reply("201.1", "continue"), self.ack)
        self.assertEqual(self.api.replies, [])
        self.assertIn("pane is busy", [f for m, f in self.slack.calls if m == "chat.postMessage"][-1]["text"])
        await self.connector.envelope(reply("201.2", "one\ntwo"), self.ack)
        self.assertEqual(self.api.replies, [])
        self.assertIn("one printable line", [f for m, f in self.slack.calls if m == "chat.postMessage"][-1]["text"])
        self.api.reply_status = "uncertain"
        self.api.lose_reply_response = True
        event = reply("201.3", "continue")
        await self.connector.envelope(event, self.ack)
        await self.connector.envelope(event, self.ack)
        self.assertEqual(self.api.replies, ["continue"])
        self.assertIn("outcome is uncertain", [f for m, f in self.slack.calls if m == "chat.postMessage"][-1]["text"])
        self.assertEqual(len([c for c in self.api.browser_calls if c["action"] == "followup" and c["text"] == "continue"]), 2)
        operation = next(c["operationID"] for c in self.api.browser_calls if c["action"] == "followup" and c.get("operationID") in self.api.receipts and self.api.receipts[c["operationID"]]["status"] == "uncertain")
        self.api.receipts[operation] = {"status": "acknowledged"}
        await self.connector.envelope(event, self.ack)
        updates = [fields for method, fields in self.slack.calls if method == "chat.update"]
        self.assertIn("reconciled locally", updates[-1]["text"])
        self.assertEqual(self.api.replies, ["continue"])

    async def test_opening_native_history_does_not_attach_or_resume(self):
        self.api.identity = lambda session_id: {"kind": "nativeCodex", "conversationID": "original-thread", "generation": "native"}
        self.api.rows[0]["backend"] = "codex"
        await self.connector.envelope(home_event(), self.ack)
        await self.connector.envelope(interaction("banyan_home", self.home_open_button()["value"], view=self.last_home()), self.ack)
        self.assertFalse(any(call["action"] in ("attach", "queue", "steer", "respond") for call in self.api.calls))
        self.assertEqual(len(self.api.mappings), 1)

    async def test_native_history_open_does_not_resume_but_explicit_reply_attaches_once(self):
        self.api.rows[0]["sessionID"] = "native"
        self.api.rows[0]["backend"] = "codex"
        self.api.identity = lambda session_id: {"kind": "nativeCodex", "conversationID": "original-thread", "generation": "native"}
        await self.connector.envelope(home_event(), self.ack)
        await self.connector.envelope(interaction("banyan_home", self.home_open_button()["value"], view=self.last_home()), self.ack)
        self.assertFalse(any(call["action"] == "attach" for call in self.api.calls))
        reply = {"envelope_id": "reply", "type": "events_api", "payload": {"team_id": "T_TEST", "event": {
            "type": "message", "user": "U_TEST", "channel": "C_TEST", "ts": "200.9", "thread_ts": "200.1", "text": "continue"}}}
        await self.connector.envelope(reply, self.ack)
        await self.connector.envelope(reply, self.ack)
        self.assertEqual(len([c for c in self.api.calls if c["action"] == "attach"]), 1)
        self.assertEqual(len([c for c in self.api.calls if c["action"] == "queue"]), 1)
        self.assertEqual(next(c for c in self.api.calls if c["action"] == "queue")["text"], "continue")

    async def test_denied_native_attach_never_replays_the_original_reply(self):
        self.api.rows[0]["sessionID"] = "native"
        self.api.rows[0]["backend"] = "codex"
        self.api.identity = lambda session_id: {"kind": "nativeCodex", "conversationID": "original-thread", "generation": "native"}
        await self.connector.envelope(home_event(), self.ack)
        await self.connector.envelope(interaction("banyan_home", self.home_open_button()["value"], view=self.last_home()), self.ack)
        reply = {"envelope_id": "reply", "type": "events_api", "payload": {"team_id": "T_TEST", "event": {
            "type": "message", "user": "U_TEST", "channel": "C_TEST", "ts": "200.9", "thread_ts": "200.1", "text": "continue"}}}
        original = self.connector.mutate

        async def denied(key, body):
            raise Denied("Authorization changed")

        self.connector.mutate = denied
        await self.connector.envelope(reply, self.ack)
        self.connector.mutate = original
        await self.connector.envelope(reply, self.ack)
        self.assertFalse(any(c["action"] in ("attach", "queue") for c in self.api.calls))

    async def test_uncertain_root_is_never_reposted(self):
        await self.connector.envelope(home_event(), self.ack)
        action = interaction("banyan_home", self.home_open_button()["value"], view=self.last_home())
        self.slack.fail_post = True
        await self.connector.envelope(action, self.ack)
        self.assertEqual(self.slack.posts, 1)
        self.slack.fail_post = False
        restarted = Connector(self.api, self.slack, self.path, [PRINCIPAL], "BOT", post_interval=0)
        await restarted.envelope(action, self.ack)
        self.assertEqual(self.slack.posts, 1)
        self.assertEqual(self.api.mappings, {})

    async def test_lost_bind_response_is_reconciled_without_another_root(self):
        await self.connector.envelope(home_event(), self.ack)
        action = interaction("banyan_home", self.home_open_button()["value"], view=self.last_home())
        self.api.bind_response_lost = True
        await self.connector.envelope(action, self.ack)
        self.assertEqual(self.slack.posts, 1)
        restarted = Connector(self.api, self.slack, self.path, [PRINCIPAL], "BOT", post_interval=0)
        await restarted.envelope(action, self.ack)
        posts = [fields for method, fields in self.slack.calls if method == "chat.postMessage"]
        self.assertEqual(len(posts), 2)
        self.assertNotIn("thread_ts", posts[0])
        self.assertEqual(posts[1]["thread_ts"], "200.1")
        self.assertEqual(len([call for call in self.api.browser_calls if call["action"] == "bind"]), 1)
        receipts = [v for k, v in restarted.journal.data["incoming"].items() if k.startswith("browser-bind-")]
        self.assertEqual([r["status"] for r in receipts], ["done"])

    async def test_known_not_sent_root_is_cancelled_if_conversation_changes(self):
        await self.connector.envelope(home_event(), self.ack)
        action = interaction("banyan_home", self.home_open_button()["value"], view=self.last_home())
        self.slack.rate_rejections = 1
        self.slack.retry_after = 0.05
        running = asyncio.create_task(self.connector.envelope(action, self.ack))
        await asyncio.wait_for(self.slack.rate_seen.wait(), 1)
        self.api.generations["row-0"] = "generation-b"
        await running
        self.assertEqual(self.slack.posts, 1)
        roots = [v for k, v in self.connector.journal.data["posts"].items() if k.startswith("browser-root-")]
        self.assertEqual([r["status"] for r in roots], ["cancelled"])
        self.assertEqual(self.api.mappings, {})

    async def test_ambiguous_home_channel_never_guesses_a_tuple(self):
        self.connector.allowed.add(("T_TEST", "C_OTHER", "U_TEST"))
        await self.connector.envelope(home_event(), self.ack)
        self.assertEqual(self.api.browser_calls, [])
        self.assertFalse(any(method == "views.publish" for method, _ in self.slack.calls))

    async def test_mention_list_supports_search_without_loading_history(self):
        event = {"envelope_id": "mention", "type": "events_api", "payload": {"team_id": "T_TEST", "event": {
            "type": "app_mention", "user": "U_TEST", "channel": "C_TEST", "ts": "500.1", "text": "<@BOT> list Beta"}}}
        await self.connector.envelope(event, self.ack)
        self.assertEqual(self.api.browser_calls[0]["action"], "list")
        self.assertEqual(self.api.browser_calls[0]["query"], "Beta")
        self.assertFalse(any(call["action"] in ("open", "boundContext") for call in self.api.browser_calls))


if __name__ == "__main__":
    unittest.main()
