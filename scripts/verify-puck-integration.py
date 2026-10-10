#!/usr/bin/env python3
"""Offline puckd/Banyan/Slack process fixture. Run from the Banyan checkout.

Requires built puckd and puck binaries with the loopback Slack test override.
Uses only temporary synthetic credentials and local HTTP/WebSocket servers.
"""

import argparse
import base64
import hashlib
import json
import os
import pathlib
import pty
import select
import shutil
import socket
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


SESSION = "a-shared"
COUNT = 35
ANSWER = "fixture done"


def wait_until(check, label, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = check()
        if result:
            return result
        time.sleep(0.05)
    raise RuntimeError(f"timed out waiting for {label}")


def response(handler, body, content_type="application/json"):
    payload = body.encode()
    handler.send_response(200)
    handler.send_header("Content-Type", content_type)
    handler.send_header("Content-Length", str(len(payload)))
    handler.send_header("Connection", "close")
    handler.end_headers()
    handler.wfile.write(payload)


class ModelHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        assert self.path == "/responses", self.path
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        history = request["input"]
        last_ask = max((index for index, item in enumerate(history)
                        if item.get("role") == "user" and "ask-question" in json.dumps(item)), default=-1)
        last_answer = max((index for index, item in enumerate(history)
                           if item.get("type") == "function_call_output"), default=-1)
        if last_ask > last_answer:
            question_number = 1 + sum(item.get("type") == "function_call_output" for item in history)
            items = [
                {"type": "response.output_text.delta", "delta": "Inspect the workspace, then summarize the findings."},
                {"type": "response.output_item.done", "item": {
                    "type": "message", "role": "assistant", "phase": "commentary",
                    "content": [{"type": "output_text", "text": "Inspect the workspace, then summarize the findings."}]}},
                {"type": "response.output_item.done", "item": {
                    "type": "function_call", "name": "request_user_input", "call_id": f"question-{question_number}",
                    "arguments": json.dumps({"questions": [{"header": "Plan",
                        "question": "Approve the plan?", "options": [
                            {"label": "Approve", "description": "Proceed."},
                            {"label": "Deny", "description": "Stop."}],
                        "default": "Deny", "custom": False}]})}},
                {"type": "response.completed", "response": {"id": "offline-question"}},
            ]
            response(self, "".join("data: " + json.dumps(item) + "\n\n" for item in items),
                     "text/event-stream")
            return
        items = [
            {"type": "response.output_text.delta", "delta": ANSWER},
            {"type": "response.output_item.done", "item": {
                "type": "message", "role": "assistant", "phase": "final_answer",
                "content": [{"type": "output_text", "text": ANSWER}]}},
            {"type": "response.completed", "response": {"id": "offline"}},
        ]
        response(self, "".join("data: " + json.dumps(item) + "\n\n" for item in items),
                 "text/event-stream")

    def log_message(self, *_args):
        pass


class SlackHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path.endswith("apps.connections.open"):
            result = {"ok": True, "url": self.server.websocket.url}
        else:
            with self.server.posts_lock:
                self.server.posts.append((self.path, body))
                ts = len(self.server.posts)
            result = {"ok": True, "ts": f"{ts}.000"}
        response(self, json.dumps(result))

    def log_message(self, *_args):
        pass


class FakeWebSocket:
    def __init__(self):
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(4)
        self.listener.settimeout(0.2)
        self.url = f"ws://127.0.0.1:{self.listener.getsockname()[1]}"
        self.stop = threading.Event()
        self.connected = threading.Event()
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.stop.is_set():
            try:
                peer, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with peer:
                peer.settimeout(2)
                headers = b""
                while b"\r\n\r\n" not in headers:
                    headers += peer.recv(4096)
                key = next(line.split(":", 1)[1].strip() for line in headers.decode().splitlines()
                           if line.lower().startswith("sec-websocket-key:"))
                digest = hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
                accept = base64.b64encode(digest).decode()
                peer.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                              "Connection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode())
                self.connected.set()
                peer.settimeout(0.2)
                while not self.stop.is_set():
                    try:
                        if not peer.recv(4096):
                            break
                    except socket.timeout:
                        pass

    def close(self):
        self.stop.set()
        self.listener.close()
        self.thread.join(timeout=2)


def server(handler):
    instance = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    thread = threading.Thread(target=instance.serve_forever, daemon=True)
    thread.start()
    return instance, thread


def rpc(path, method, params=None):
    request = {"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}
    with socket.socket(socket.AF_UNIX) as peer:
        peer.settimeout(10)
        peer.connect(str(path))
        peer.sendall((json.dumps(request) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            data += peer.recv(65536)
    reply = json.loads(data)
    if "error" in reply:
        raise RuntimeError(f"{method}: {reply['error']}")
    return reply["result"]


def daemon_is_ready(path, empty=True):
    if not path.exists():
        return False
    try:
        sessions = rpc(path, "session.list")
        return sessions == [] if empty else True
    except (OSError, TimeoutError):
        return False


def rss_kib(pid):
    return int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], text=True).strip())


def descendants(pid):
    rows = subprocess.check_output(["ps", "-A", "-o", "pid=,ppid=,comm="], text=True).splitlines()
    children = {}
    for row in rows:
        child, parent, command = row.strip().split(None, 2)
        children.setdefault(int(parent), []).append((int(child), command))
    found = []
    pending = [pid]
    while pending:
        for child, command in children.get(pending.pop(), []):
            found.append((child, command))
            pending.append(child)
    return found


def pty_process(command, env):
    master, slave = pty.openpty()
    process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave,
                               env=env, start_new_session=True)
    os.close(slave)
    os.set_blocking(master, False)
    return process, master


def read_pty_until(process, descriptor, phrase, timeout=30):
    output = bytearray()
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"client exited before {phrase!r}: {output[-1500:]!r}")
        ready, _, _ = select.select([descriptor], [], [], 0.1)
        if ready:
            try:
                output.extend(os.read(descriptor, 65536))
            except BlockingIOError:
                pass
            if phrase.encode() in output:
                return output.decode(errors="replace")
    raise RuntimeError(f"client did not show {phrase!r}: {output[-1500:]!r}")


def stop_process(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def write_account(home):
    account = home / "accounts" / "codex" / "fixture.json"
    account.parent.mkdir(parents=True, mode=0o700)
    value = {"provider": "codex", "label": "fixture", "tokens": {
        "access_token": "synthetic-offline-access",
        "refresh_token": "synthetic-unused-refresh", "id_token": "synthetic-offline-id"}}
    descriptor = os.open(account, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as stream:
        json.dump(value, stream)


def clean_environment(root, puck_home, model_url, slack_url):
    allowed = ("PATH", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TMPDIR",
               "DEVELOPER_DIR", "TOOLCHAINS", "SDKROOT")
    env = {key: os.environ[key] for key in allowed if key in os.environ}
    env.update({"HOME": str(root / "home"), "PUCK_HOME": str(puck_home),
                "PUCK_BASE_URL": model_url, "TMUX_TMPDIR": str(root / "tmux"),
                "PUCK_SLACK_API_BASE": slack_url,
                "PUCK_SLACK_APP_TOKEN": "xapp-synthetic",
                "PUCK_SLACK_BOT_TOKEN": "xoxb-synthetic",
                "PUCK_SLACK_CHANNEL": "C-fixture",
                "PUCK_SLACK_ALLOWED_USERS": "U-fixture",
                "PUCK_SESSION_URL_TEMPLATE": "https://example.invalid/open?session={session}"})
    return env


def app_session_test(repo, env, prior_cursor, ready_file=None):
    app_env = env.copy()
    app_env["BANYAN_PUCK_E2E_SESSION"] = SESSION
    app_env["BANYAN_PUCK_E2E_AFTER_CURSOR"] = str(prior_cursor)
    if ready_file:
        app_env["BANYAN_PUCK_E2E_READY_FILE"] = str(ready_file)
    return subprocess.Popen(["swift", "test", "--quiet", "--filter",
                             "appPuckSessionSeesSharedDaemonSessionAndItsEvents"],
                            cwd=repo, env=app_env, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)


def run(args):
    repo = pathlib.Path(__file__).resolve().parents[1]
    for binary in (args.puckd, args.puck, args.banyanctl, args.banyantui):
        if not binary.is_file():
            raise RuntimeError(f"build required binary first: {binary}")
    if not shutil.which("tmux"):
        raise RuntimeError("BanyanTUI needs tmux in PATH")
    with tempfile.TemporaryDirectory(prefix="puck-banyan-e2e-", dir="/tmp") as scratch:
        root = pathlib.Path(scratch)
        for name in ("home", "tmux", "workspace", "banyan-data"):
            (root / name).mkdir(mode=0o700)
        puck_home = root / "puck"
        puck_home.mkdir(mode=0o700)
        write_account(puck_home)
        baseline_home = root / "baseline"
        baseline_home.mkdir(mode=0o700)
        write_account(baseline_home)
        websocket = FakeWebSocket()
        model, model_thread = server(ModelHandler)
        slack, slack_thread = server(SlackHandler)
        slack.websocket = websocket
        slack.posts = []
        slack.posts_lock = threading.Lock()
        model_url = f"http://127.0.0.1:{model.server_port}"
        slack_url = f"http://127.0.0.1:{slack.server_port}/api"
        env = clean_environment(root, puck_home, model_url, slack_url)
        env["BANYAN_FIXTURE_DATA_HOME"] = str(root / "banyan-data")
        processes = []
        log = None
        try:
            isolation = subprocess.run(["swift", "test", "--quiet", "--filter",
                "processFixtureDataHomeResolvesInsideTemporaryRoot"], cwd=repo,
                env=env, capture_output=True, text=True, timeout=120)
            assert isolation.returncode == 0 and "1 test" in isolation.stdout, isolation.stdout[-2000:]
            assert not (root / "banyan-data/Banyan/state.sqlite").exists()
            log = open(root / "puckd.log", "w")
            daemon = subprocess.Popen([str(args.puckd), "--idle-seconds", "3600"],
                                      env=env, stdout=log, stderr=subprocess.STDOUT)
            processes.append(daemon)
            path = puck_home / "daemon" / "puck.sock"
            wait_until(lambda: daemon_is_ready(path), "empty puckd", timeout=15)
            wait_until(websocket.connected.is_set, "fake Slack Socket Mode", timeout=15)
            empty_rss = rss_kib(daemon.pid)
            ids = [SESSION] + [f"session-{number:02}" for number in range(COUNT - 1)]
            for session_id in ids:
                rpc(path, "session.create", {"engine": "native", "id": session_id, "provider": "codex",
                    "account": "fixture", "workspace": str(root / "workspace"),
                    "model": "fixture-model", "settings": {"approval": "deny",
                    "exec": False, "fetch": False, "search": False}})
                rpc(path, "session.turn", {"session": session_id, "prompt": "fixture"})
                wait_until(lambda: rpc(path, "session.get", {"session": session_id})["position"] == "idle",
                           f"idle {session_id}")
            assert len(rpc(path, "session.list")) == COUNT
            time.sleep(0.4)
            daemon_rss = rss_kib(daemon.pid)
            baseline_env = env.copy()
            baseline_env["PUCK_HOME"] = str(baseline_home)
            baseline, baseline_tty = pty_process([str(args.puck), "chat", "--engine", "native", "--provider", "codex",
                "--account", "fixture", "--model", "fixture-model", "--workspace", str(root / "workspace"),
                "--approval", "deny", "--exec", "off", "--fetch", "off", "--search", "off",
                "--ask", "off", "baseline"], baseline_env)
            processes.append(baseline)
            read_pty_until(baseline, baseline_tty, "puck> ")
            cli_rss = rss_kib(baseline.pid)
            os.write(baseline_tty, b"/quit\n")
            baseline.wait(timeout=5)
            os.close(baseline_tty)
            ratio = daemon_rss / (COUNT * cli_rss)
            assert ratio < 0.25, f"RSS ratio {ratio:.3f} is not far below {COUNT} CLIs"
            assert not descendants(daemon.pid), "idle puckd spawned child processes"

            # A fresh app process follows the session before a new event arrives.
            prior_cursor = rpc(path, "session.events", {"session": SESSION})["cursor"]
            ready = root / "app-ready"
            app = app_session_test(repo, env, prior_cursor, ready)
            processes.append(app)
            wait_until(ready.exists, "app session attachment", timeout=120)
            tui, tui_tty = pty_process([str(args.banyantui)], env)
            processes.append(tui)
            read_pty_until(tui, tui_tty, "id: " + SESSION)
            os.write(tui_tty, b"\r")
            detail = read_pty_until(tui, tui_tty, "puck> ")
            assert SESSION in detail, "TUI attached to the wrong daemon session"
            os.write(tui_tty, b"/detach\n")
            read_pty_until(tui, tui_tty, "Banyan TUI")
            stop_process(tui)
            os.close(tui_tty)
            ctl_list = subprocess.check_output([str(args.banyanctl), "session", "list"],
                                                env=env, text=True)
            assert any(row.get("id") == SESSION and row.get("backend") == "puck"
                       for row in json.loads(ctl_list)["sessions"])
            ctl, ctl_tty = pty_process([str(args.banyanctl), "puck", "attach", "--id", SESSION], env)
            processes.append(ctl)
            detail = read_pty_until(ctl, ctl_tty, "Enter a prompt")
            assert SESSION in detail, "banyanctl attached to the wrong daemon session"
            os.write(ctl_tty, b"/detach\n")
            ctl.wait(timeout=5)
            os.close(ctl_tty)

            def shared_slack_posts():
                with slack.posts_lock:
                    posts = list(slack.posts)
                roots = [(index, body) for index, (_path, body) in enumerate(posts, 1)
                         if body.get("text", "").startswith("puck session " + SESSION + " ·")]
                if not roots:
                    return None
                thread_ts = f"{roots[0][0]}.000"
                finished = sum(1 for _path, body in posts
                               if body.get("thread_ts") == thread_ts and body.get("text") == "Finished.")
                return thread_ts, finished

            wait_until(lambda: (shared_slack_posts() or (None, 0))[1] >= 1,
                       "initial event in shared Slack thread")
            thread_ts, prior_slack_finishes = shared_slack_posts()
            rpc(path, "session.turn", {"session": SESSION, "prompt": "shared event"})
            wait_until(lambda: rpc(path, "session.get", {"session": SESSION})["position"] == "idle",
                       "shared turn")
            output, _ = app.communicate(timeout=35)
            assert app.returncode == 0 and "Test run with 1 test" in output, output[-2000:]
            wait_until(lambda: (shared_slack_posts() or (None, 0))[0] == thread_ts
                       and (shared_slack_posts() or (None, 0))[1] > prior_slack_finishes,
                       "new event in shared Slack thread")
            events = rpc(path, "session.events", {"session": SESSION})["events"]
            assert any(event["cursor"] > prior_cursor and event["data"]["event"] == "turn_done"
                       for event in events)

            # The app client process exits, then a new one replays the same daemon state.
            restarted = app_session_test(repo, env, prior_cursor)
            processes.append(restarted)
            restarted_output, _ = restarted.communicate(timeout=35)
            assert restarted.returncode == 0 and "Test run with 1 test" in restarted_output, restarted_output[-2000:]
            assert len(rpc(path, "session.list")) == COUNT
            assert not descendants(daemon.pid)

            def parked_question(session_id):
                rpc(path, "session.create", {"engine": "native", "id": session_id, "provider": "codex",
                    "account": "fixture", "workspace": str(root / "workspace"),
                    "model": "fixture-model", "settings": {"approval": "ask",
                    "exec": False, "fetch": False, "search": False}})
                rpc(path, "session.turn", {"session": session_id, "prompt": "ask-question"})
                return wait_until(lambda: (summary if (summary := rpc(path, "session.get",
                    {"session": session_id}))["position"] == "parked" else None),
                    f"parked question {session_id}")

            question = parked_question("question-ctl")
            assert question["pending_question"]["call_id"] == "question-1"
            shown = subprocess.check_output([str(args.banyanctl), "puck", "show", "--id", "question-ctl"],
                                            env=env, text=True)
            assert "Approve the plan?" in shown and "Approve — Proceed." in shown
            plan = subprocess.check_output([str(args.banyanctl), "puck", "plan", "--id", "question-ctl"],
                                           env=env, text=True)
            assert "Inspect the workspace" in plan
            subprocess.run([str(args.banyanctl), "puck", "reject", "--id", "question-ctl",
                "--call-id", "question-1", "--reason", "fixture audit only"], env=env, check=True)
            assert rpc(path, "session.get", {"session": "question-ctl"})["position"] == "parked"
            answer = '[{"labels":["Approve"],"text":null}]'
            stale = subprocess.run([str(args.banyanctl), "puck", "answer", "--id", "question-ctl",
                "--call-id", "stale", "--selections", answer], env=env, capture_output=True, text=True)
            assert stale.returncode != 0
            assert rpc(path, "session.get", {"session": "question-ctl"})["position"] == "parked"
            subprocess.run([str(args.banyanctl), "puck", "answer", "--id", "question-ctl",
                "--call-id", "question-1", "--selections", answer], env=env, check=True)
            wait_until(lambda: rpc(path, "session.get", {"session": "question-ctl"})["position"] == "idle",
                       "answered CLI question")

            parked_question("question-app")
            question_app_env = env.copy()
            question_app_env["BANYAN_PUCK_E2E_QUESTION_SESSION"] = "question-app"
            question_app = subprocess.run(["swift", "test", "--quiet", "--filter",
                "appPuckSessionAnswersParkedQuestion"], cwd=repo, env=question_app_env,
                capture_output=True, text=True, timeout=120)
            assert question_app.returncode == 0 and "1 test" in question_app.stdout, question_app.stdout[-2000:]
            wait_until(lambda: rpc(path, "session.get", {"session": "question-app"})["position"] == "idle",
                       "answered app question")

            parked_question("question-tui")
            question_tui_env = env.copy()
            question_tui_env["BANYAN_PUCK_E2E_TUI_QUESTION_SESSION"] = "question-tui"
            question_tui = subprocess.run(["swift", "test", "--quiet", "--filter",
                "tuiAnswersParkedPuckQuestion"], cwd=repo, env=question_tui_env,
                capture_output=True, text=True, timeout=120)
            assert question_tui.returncode == 0 and "1 test" in question_tui.stdout, question_tui.stdout[-2000:]
            wait_until(lambda: rpc(path, "session.get", {"session": "question-tui"})["position"] == "idle",
                       "answered TUI question")

            # A long-lived Banyan watch claims the interactive capability, and
            # sends its real presence reports on that very same connection.
            presence_id = "question-presence"
            rpc(path, "session.create", {"engine": "native", "id": presence_id, "provider": "codex",
                "account": "fixture", "workspace": str(root / "workspace"),
                "model": "fixture-model", "settings": {"approval": "ask",
                "exec": False, "fetch": False, "search": False}})
            presence_ready = root / "presence-ready"
            away_trigger = root / "away-trigger"
            away_ready = root / "away-ready"
            presence_env = env.copy()
            presence_env.update({"BANYAN_PUCK_E2E_PRESENCE_SESSION": presence_id,
                "BANYAN_PUCK_E2E_PRESENCE_READY": str(presence_ready),
                "BANYAN_PUCK_E2E_AWAY_TRIGGER": str(away_trigger),
                "BANYAN_PUCK_E2E_AWAY_READY": str(away_ready)})
            presence_app = subprocess.Popen(["swift", "test", "--skip-build", "--filter",
                "appPuckPresenceRoutesDeskThenAway"], cwd=repo, env=presence_env,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            processes.append(presence_app)
            wait_until(presence_ready.exists, "Banyan interactive presence", timeout=120)
            assert rpc(path, "presence.get")["present"] is True
            # Let prior fixture posts drain before measuring the quiet interval.
            time.sleep(1)
            with slack.posts_lock:
                before_desk = len(slack.posts)
            rpc(path, "session.turn", {"session": presence_id, "prompt": "ask-question"})
            wait_until(lambda: rpc(path, "session.get", {"session": presence_id})["position"] == "parked",
                       "desk ask")
            asks = [event["data"] for event in rpc(path, "session.events", {"session": presence_id})["events"]
                    if event["data"]["event"] == "blocked_on_question"]
            assert asks[-1]["route"] == "interactive" and asks[-1]["notify"] is False, asks
            time.sleep(0.5)
            with slack.posts_lock:
                assert len(slack.posts) == before_desk, "Slack posted while Banyan was present"
            rpc(path, "session.answer", {"session": presence_id, "call_id": "question-1",
                "selections": [{"labels": ["Approve"], "text": None}]})
            wait_until(lambda: rpc(path, "session.get", {"session": presence_id})["position"] == "idle",
                       "desk answer")
            away_trigger.touch()
            wait_until(away_ready.exists, "Banyan display-sleep away report")
            assert rpc(path, "presence.get")["present"] is False
            rpc(path, "session.turn", {"session": presence_id, "prompt": "ask-question again"})
            wait_until(lambda: rpc(path, "session.get", {"session": presence_id})["position"] == "parked",
                       "away ask")
            asks = [event["data"] for event in rpc(path, "session.events", {"session": presence_id})["events"]
                    if event["data"]["event"] == "blocked_on_question"]
            assert asks[-1]["route"] == "notify" and asks[-1]["notify"] is True, asks
            wait_until(lambda: any(presence_id in body.get("text", "")
                for _path, body in list(slack.posts)), "Slack catch-up after away")
            wait_until(lambda: any("question-2" in json.dumps(body)
                for _path, body in list(slack.posts)), "next ask delivered to Slack")
            presence_output, _ = presence_app.communicate(timeout=35)
            assert presence_app.returncode == 0 and "1 test" in presence_output, presence_output[-3000:]

            reconnect_ready = root / "reconnect-ready"
            reconnect_lost = root / "reconnect-lost"
            reconnect_resumed = root / "reconnect-resumed"
            reconnect_env = env.copy()
            reconnect_env.update({"BANYAN_PUCK_E2E_RECONNECT_SESSION": SESSION,
                "BANYAN_PUCK_E2E_RECONNECT_READY": str(reconnect_ready),
                "BANYAN_PUCK_E2E_RECONNECT_LOST": str(reconnect_lost),
                "BANYAN_PUCK_E2E_RECONNECT_RESUMED": str(reconnect_resumed)})
            reconnect_app = subprocess.Popen(["swift", "test", "--skip-build", "--filter",
                "appPuckReattachesAfterDaemonRestart"], cwd=repo, env=reconnect_env,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            processes.append(reconnect_app)
            wait_until(reconnect_ready.exists, "app attached before daemon restart")
            session_count = len(rpc(path, "session.list"))
            stop_process(daemon)
            wait_until(reconnect_lost.exists, "app observed daemon exit")
            daemon = subprocess.Popen([str(args.puckd), "--idle-seconds", "3600"],
                                      env=env, stdout=log, stderr=subprocess.STDOUT)
            processes.append(daemon)
            wait_until(lambda: daemon_is_ready(path, empty=False), "restarted puckd", timeout=15)
            assert len(rpc(path, "session.list")) == session_count
            wait_until(reconnect_resumed.exists, "app reattached without user action")
            rpc(path, "session.turn", {"session": SESSION, "prompt": "after daemon restart"})
            reconnect_output, _ = reconnect_app.communicate(timeout=35)
            assert reconnect_app.returncode == 0 and "1 test" in reconnect_output, reconnect_output[-3000:]
            assert not descendants(daemon.pid)
            print(json.dumps({"sessions": COUNT, "emptyDaemonKiB": empty_rss,
                              "idleDaemonKiB": daemon_rss, "singleCliKiB": cli_rss,
                              "rssVs35Cli": round(ratio, 4), "appRestart": "passed",
                              "tui": "passed", "ctl": "passed", "fakeSlack": "passed",
                              "parkedQuestions": "ctl/app/tui passed",
                              "presence": "desk quiet, away catch-up, next ask to Slack passed",
                              "daemonRestart": "automatic replay and live turn passed",
                              "daemonChildren": 0}, sort_keys=True))
        except Exception:
            if (root / "puckd.log").exists():
                print((root / "puckd.log").read_text()[-3000:])
            raise
        finally:
            for process in reversed(processes):
                stop_process(process)
            if log:
                log.close()
            slack.shutdown()
            model.shutdown()
            websocket.close()
            slack_thread.join(timeout=2)
            model_thread.join(timeout=2)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--puckd", type=pathlib.Path, required=True)
    parser.add_argument("--puck", type=pathlib.Path, required=True)
    parser.add_argument("--banyanctl", type=pathlib.Path, required=True)
    parser.add_argument("--banyantui", type=pathlib.Path, required=True)
    run(parser.parse_args())
