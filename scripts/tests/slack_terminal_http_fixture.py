#!/usr/bin/env python3
"""Fake Slack against a disposable Banyan HTTP server and owned fake pane."""
import asyncio
import copy
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from banyan_slack.connector import Connector
from banyan_slack.runtime import LocalAPI

PRINCIPAL = {"workspace": "T_TEST", "channel": "C_TEST", "user": "U_TEST"}


class FakeSlack:
    def __init__(self):
        self.calls = []
        self.posts = 0

    async def call(self, method, **fields):
        self.calls.append((method, copy.deepcopy(fields)))
        if method == "chat.postMessage":
            self.posts += 1
            return {"ts": f"200.{self.posts}"}
        return {"ok": True}


async def drive(config):
    slack = FakeSlack()
    connector = Connector(LocalAPI(config["controlURL"], config["tokenFile"]), slack, config["state"], [PRINCIPAL], "BOT", post_interval=0)
    acked = []

    async def ack(value):
        acked.append(value)

    home = {"envelope_id": "home", "type": "events_api", "payload": {"team_id": "T_TEST", "event": {
        "type": "app_home_opened", "tab": "home", "user": "U_TEST"}}}
    await connector.envelope(home, ack)
    view = next(fields["view"] for method, fields in reversed(slack.calls) if method == "views.publish")
    if config.get("mode") in ("away", "puck_away", "native_away"):
        follow = next(element for block in view["blocks"] if block.get("type") == "actions"
                      for element in block["elements"] if element["text"]["text"] == "Follow")
        await connector.envelope({"envelope_id": "follow", "type": "interactive", "payload": {
            "type": "block_actions", "team": {"id": "T_TEST"}, "user": {"id": "U_TEST"},
            "view": view, "actions": [{**follow, "action_ts": "300.1"}]}}, ack)
        view = next(fields["view"] for method, fields in reversed(slack.calls) if method == "views.publish")
        toggle = next(element for block in view["blocks"] if block.get("type") == "actions"
                      for element in block["elements"] if element["text"]["text"] == "Turn Away on")
        await connector.envelope({"envelope_id": "away", "type": "interactive", "payload": {
            "type": "block_actions", "team": {"id": "T_TEST"}, "user": {"id": "U_TEST"},
            "view": view, "actions": [{**toggle, "action_ts": "300.2"}]}}, ack)
        await connector.refresh_away(PRINCIPAL)
        digests = [fields for method, fields in slack.calls if method == "chat.postMessage" and fields["text"].startswith("Away catch-up")]
        expected = {"puck_away": "Approval needed: shell", "native_away": "Command approval requested"}.get(config.get("mode"), "Do you want to proceed?")
        assert len(digests) == 1 and expected in digests[0]["text"]
    else:
        button = next(block["accessory"] for block in view["blocks"] if "accessory" in block)
        open_action = {"envelope_id": "open", "type": "interactive", "payload": {
            "type": "block_actions", "team": {"id": "T_TEST"}, "user": {"id": "U_TEST"},
            "view": view, "actions": [{**button, "action_ts": "300.1"}]}}
        await connector.envelope(open_action, ack)
    if config.get("mode") == "followup":
        reply = {"envelope_id": "reply", "type": "events_api", "payload": {"team_id": "T_TEST", "event": {
            "type": "message", "channel": "C_TEST", "user": "U_TEST", "thread_ts": "100.1",
            "ts": "100.9", "text": "Please continue"}}}
        await connector.envelope(reply, ack)
        await connector.envelope({**reply, "envelope_id": "reply-redelivery"}, ack)
        receipts = [entry for key, entry in connector.journal.data["incoming"].items() if key.startswith("browser-followup-")]
        assert len(receipts) == 1 and receipts[0]["result"]["status"] == "submitted"
        assert len(acked) == 4
        print(json.dumps({"ok": True, "replyReceipts": len(receipts)}))
        return
    if config.get("mode") == "native_away":
        panel = next(fields for method, fields in slack.calls if method == "chat.postMessage" and
                     fields.get("metadata", {}).get("event_payload", {}).get("delivery_id", "").startswith("status-"))
        assert any("Command approval requested" in block.get("text", {}).get("text", "") for block in panel["blocks"])
        choice = next(element for block in panel["blocks"] if block.get("type") == "actions"
                      for element in block["elements"] if element["text"]["text"] == "Deny")
        answer = {"envelope_id": "answer", "type": "interactive", "payload": {
            "type": "block_actions", "team": {"id": "T_TEST"}, "channel": {"id": "C_TEST"},
            "user": {"id": "U_TEST"}, "container": {"message_ts": "200.3"},
            "actions": [{**choice, "action_ts": "300.2"}]}}
        await connector.envelope(answer, ack)
        await connector.envelope({**answer, "envelope_id": "answer-redelivery"}, ack)
        receipts = [entry for entry in connector.journal.data["incoming"].values() if entry.get("body", {}).get("action") == "respond"]
        assert len(receipts) == 1 and receipts[0]["result"]["status"] == "submitted"
        print(json.dumps({"ok": True, "answerReceipts": len(receipts)}))
        return
    puck = config.get("mode") in ("puck", "puck_away", "puck_question")
    card = next(fields for method, fields in slack.calls if method == "chat.postMessage" and fields["text"] == ("Puck decision" if puck else "Terminal decision"))
    texts = [block.get("text", {}).get("text", "") for block in card["blocks"]]
    if config.get("mode") == "puck_question":
        assert "Which checks?" in texts and "Any details?" in texts
        button = next(element for block in card["blocks"] if block.get("type") == "actions"
                      for element in block["elements"] if element["text"]["text"] == "Answer questions")
        await connector.envelope({"envelope_id": "question", "type": "interactive", "payload": {
            "type": "block_actions", "team": {"id": "T_TEST"}, "channel": {"id": "C_TEST"},
            "user": {"id": "U_TEST"}, "trigger_id": "TRIGGER", "actions": [{**button, "action_ts": "300.2"}]}}, ack)
        modal = next(fields["view"] for method, fields in slack.calls if method == "views.open")
        values = {"q0-choice": {"choice": {"selected_options": [{"value": "B"}, {"value": "A"}]}},
                  "q1-custom": {"custom": {"value": "details"}}}
        submit = {"envelope_id": "modal", "type": "interactive", "payload": {"type": "view_submission",
            "team": {"id": "T_TEST"}, "user": {"id": "U_TEST"},
            "view": {**modal, "id": "VIEW", "state": {"values": values}}}}
        await connector.envelope(submit, ack)
        await connector.envelope({**submit, "envelope_id": "modal-redelivery"}, ack)
        receipts = [entry for key, entry in connector.journal.data["incoming"].items() if key.startswith("browser-answer-")]
        assert len(receipts) == 1 and receipts[0]["result"]["status"] == "submitted"
        print(json.dumps({"ok": True, "answerReceipts": len(receipts)}))
        return
    if puck:
        assert "Approval needed: shell" in texts
        assert "1. Approve" in texts and "3. Deny" in texts
        assert any("prior context" in text for text in texts)
    else:
        assert "Do you want to proceed?" in texts
        assert "1. Yes" in texts and "2. No" in texts
        assert any("Earlier context" in text for text in texts)
    choice = next(element for block in card["blocks"] if block.get("type") == "actions"
                  for element in block["elements"] if element["text"]["text"] == ("3" if puck else "2"))
    answer = {"envelope_id": "answer", "type": "interactive", "payload": {
        "type": "block_actions", "team": {"id": "T_TEST"}, "channel": {"id": "C_TEST"},
        "user": {"id": "U_TEST"}, "container": {"message_ts": "200.2"},
        "actions": [{**choice, "action_ts": "300.2"}]}}
    await connector.envelope(answer, ack)
    await connector.envelope({**answer, "envelope_id": "answer-redelivery"}, ack)
    receipts = [entry for key, entry in connector.journal.data["incoming"].items() if key.startswith("browser-answer-")]
    assert len(receipts) == 1 and receipts[0]["result"]["status"] == "submitted"
    assert len(acked) == (5 if config.get("mode") in ("away", "puck_away") else 4)
    print(json.dumps({"ok": True, "answerReceipts": len(receipts)}))


if __name__ == "__main__":
    asyncio.run(drive(json.loads(Path(sys.argv[1]).read_text())))
