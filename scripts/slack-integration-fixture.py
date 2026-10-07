#!/usr/bin/env python3
"""Fake Slack transport against a private REAL Banyan HTTP control server."""
import asyncio
import copy
import json
from pathlib import Path
import sys
import time

from banyan_slack.connector import Connector, Unavailable
from banyan_slack.runtime import LocalAPI

PRINCIPAL = {"workspace": "T_TEST", "channel": "C_TEST", "user": "U_TEST"}


class SlackFixture:
    def __init__(self):
        self.calls = []
        self.posts = 0

    async def call(self, method, **fields):
        self.calls.append((method, copy.deepcopy(fields)))
        if method == "chat.postMessage":
            self.posts += 1
            return {"ok": True, "ts": f"200.{self.posts}"}
        return {"ok": True}


async def drive(config):
    root = Path(config["root"])
    api = LocalAPI(config["controlURL"], config["tokenFile"])
    slack = SlackFixture()
    state = root / "connector.json"
    connector = Connector(api, slack, state, [PRINCIPAL], "BOT", post_interval=0)
    acked = []
    number = 0

    async def ack(value):
        acked.append(value)

    async def message(text, attach=False):
        nonlocal number
        number += 1
        ts = f"100.{number}"
        event = {"type": "app_mention" if attach else "message", "channel": "C_TEST", "user": "U_TEST", "text": text, "ts": ts}
        if not attach:
            event["thread_ts"] = "100.1"
        envelope = {"type": "events_api", "envelope_id": f"delivery-{number}", "payload": {"team_id": "T_TEST", "event": event}}
        await connector.envelope(envelope, ack)
        return envelope

    async def snapshot():
        session = next(iter(connector.sessions.values()))
        result = await api.call({"action": "snapshot", "principal": PRINCIPAL, **connector.binding(session)})
        assert result["threadID"] == config["threadID"], "Thread identity changed"
        connector.sessions[result["attachment"]["id"]] = result
        return result

    async def wait(predicate, label):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            value = await snapshot()
            if predicate(value):
                return value
            await asyncio.sleep(0.03)
        raise AssertionError(f"Timed out: {label}; state={value['state']} requests={len(value['requests'])}")

    async def completed(prompt):
        return await wait(lambda s: s["lastTurnStatus"] == "completed" and any(i["text"] == prompt for i in s["context"]), prompt)

    async def button(label, fresh=True):
        session = await snapshot()
        if fresh:
            await connector.render(session, PRINCIPAL)
        for method, fields in reversed(slack.calls):
            if method not in ("chat.update", "chat.postMessage"):
                continue
            for block in fields.get("blocks", []):
                for control in block.get("elements", []):
                    if control.get("text", {}).get("text") == label:
                        return control
        raise AssertionError(f"No button {label}")

    async def click(control):
        nonlocal number
        number += 1
        payload = {"type": "block_actions", "team": {"id": "T_TEST"}, "channel": {"id": "C_TEST"},
            "user": {"id": "U_TEST"}, "container": {"message_ts": "200.1"}, "trigger_id": "fixture-trigger",
            "actions": [{**control, "action_ts": f"300.{number}"}]}
        envelope = {"type": "interactive", "envelope_id": f"action-{number}", "payload": payload}
        await connector.envelope(envelope, ack)
        return envelope

    await message("<@BOT> attach native", attach=True)
    assert len(connector.sessions) == 1
    attachment = (await snapshot())["attachment"]
    original = await message("fixture:slack-followup")
    await completed("fixture:slack-followup")
    # Reconnect/restart restores mapping and receipt; redelivery never starts a turn.
    connector = Connector(api, slack, state, [PRINCIPAL], "BOT", post_interval=0)
    await connector.refresh(PRINCIPAL, first=True)
    assert (await snapshot())["attachment"] == attachment
    await connector.envelope({**original, "envelope_id": "replayed-after-restart"}, ack)

    await message("fixture:approve")
    await wait(lambda s: bool(s["requests"]), "approval")
    approve = await button("Approve Once")
    delivery = await click(approve)
    await connector.envelope({**delivery, "envelope_id": "duplicate-approval"}, ack)
    await completed("fixture:approve")
    assert (Path(config["cwd"]) / "approve-proof.txt").read_text() == "APPROVED"
    await click(approve)  # Stale distinct action has no runtime effect.

    await message("fixture:question")
    await wait(lambda s: bool(s["requests"]), "question")
    await click(await button("Answer questions"))
    modal = next(fields["view"] for method, fields in reversed(slack.calls) if method == "views.open")
    await connector.envelope({"type": "interactive", "envelope_id": "answer", "payload": {
        "type": "view_submission", "team": {"id": "T_TEST"}, "user": {"id": "U_TEST"},
        "view": {**modal, "id": "V_FIXTURE", "state": {"values": {"choice": {"answer": {"selected_option": {"value": "Alpha"}}}}}}}}, ack)
    await completed("fixture:question")

    (root / "release-steer").unlink(missing_ok=True)
    await message("fixture:steer")
    await wait(lambda s: bool(s["turnID"]), "steer active")
    await message("fixture:steered")
    await click(await button("Steer current turn", fresh=False))
    (root / "release-steer").touch()
    await wait(lambda s: s["lastTurnStatus"] == "completed", "steer completed")
    (root / "release-steer").unlink(missing_ok=True)

    await message("fixture:interrupt")
    await wait(lambda s: bool(s["turnID"]), "interrupt active")
    await message("fixture:hello-queued")
    before = await snapshot()
    assert any(r["status"] == "queued" for r in before["receipts"])
    await click(await button("Stop turn"))
    await completed("fixture:hello-queued")
    await connector.refresh(PRINCIPAL, first=True)
    assert (await snapshot())["threadID"] == config["threadID"]
    assert Path(config["cwd"]).is_dir()
    # Disabled API rejects both reads/actions and subsequent outbound delivery.
    await asyncio.to_thread(api._call, "/codex-remote-configure", {"enabled": False, "allowed": [PRINCIPAL]})
    posted = len(slack.calls)
    await message("fixture:must-not-run")
    assert len(slack.calls) == posted
    await connector.stop()
    result = {"originalThreadID": config["threadID"], "attachmentRestored": True, "acknowledgments": len(acked),
        "fakeSlackCalls": len(slack.calls), "phoneVerified": False,
        "checks": ["follow-up", "approval", "question", "queue", "steer", "stop", "restart-dedup", "stale-controls", "disable"]}
    (root / "slack-result.json").write_text(json.dumps(result, indent=2))
    print("Fake Slack -> authenticated Banyan HTTP -> installed Codex: PASS")


if __name__ == "__main__":
    asyncio.run(drive(json.loads(Path(sys.argv[1]).read_text())))
