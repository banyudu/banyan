"""Real outbound Socket Mode adapter; imported only by explicit connector start."""
import argparse
import asyncio
import fcntl
import json
import logging
import os
import re
from pathlib import Path
import signal
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request

from .connector import Connector, Denied, RateLimited, StaleAttachment, Unavailable


class LocalAPI:
    def __init__(self, url, token_file):
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme != "http" or parsed.hostname != "127.0.0.1" or parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise Unavailable("Control URL must use HTTP loopback")
        self.url = url.rstrip("/")
        self.token_file = Path(token_file)

    async def call(self, body):
        return await asyncio.to_thread(self._call, "/codex-remote", body)

    def _call(self, path, body):
        token = self.token_file.read_text().strip()
        if not token:
            raise Unavailable("Local control token is missing")
        request = urllib.request.Request(self.url + path, data=json.dumps(body).encode(), method="POST",
            headers={"Content-Type": "application/json", "X-Banyan-Token": token})
        # No redirects: keep the control token on loopback, even on a bad URL.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs):
                return None
        try:
            with urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect()).open(request, timeout=35) as response:
                result = json.loads(response.read(8 * 1024 * 1024))
            if not result.get("ok"):
                raise Unavailable("Banyan rejected control request")
            return result["data"]
        except urllib.error.HTTPError as error:
            if error.code in (401, 403):
                raise Denied("Banyan control authorization refused") from None
            if error.code == 409 and body.get("action") == "snapshot":
                raise StaleAttachment("Attachment no longer current") from None
            raise Unavailable("Banyan control API unavailable") from None
        except Denied:
            raise
        except Exception:
            raise Unavailable("Banyan control API unavailable") from None


class SlackTransport:
    def __init__(self, web):
        self.web = web

    async def call(self, method, **fields):
        return await asyncio.to_thread(self._call, method, fields)

    def _call(self, method, fields):
        from slack_sdk.errors import SlackApiError
        try:
            return self.web.api_call(method, json=fields)
        except SlackApiError as error:
            if error.response.status_code == 429:
                headers = {k.lower(): v for k, v in error.response.headers.items()}
                delay = headers.get("retry-after", "1")
                if isinstance(delay, (list, tuple)):
                    delay = delay[0]
                raise RateLimited(delay) from None
            raise


class ProcessLock:
    def __init__(self, state_path):
        path = Path(str(state_path) + ".lock")
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.descriptor = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            os.close(self.descriptor)
            raise Unavailable("Another connector already owns this journal") from None

    def close(self):
        os.close(self.descriptor)


async def run(args, stopped=None):
    # No SDK debug logs: its HTTP diagnostics can contain tokens or content.
    quiet = logging.getLogger("banyan.slack.transport")
    quiet.disabled = True
    quiet.propagate = False
    quiet.addHandler(logging.NullHandler())
    from slack_sdk import WebClient
    from slack_sdk.socket_mode import SocketModeClient
    from slack_sdk.socket_mode.builtin.connection import Connection
    from slack_sdk.socket_mode.builtin.client import ConnectionState
    from .socket_adapter import fenced_socket_client
    from slack_sdk.socket_mode.response import SocketModeResponse

    config = json.loads(Path(args.config).read_text())
    if not config.get("enabled") or not config.get("allowed"):
        raise Unavailable("Connector requires enabled=true and a nonempty tuple allowlist")
    app_token = os.environ.get("SLACK_APP_TOKEN", "")
    bot_token = os.environ.get("SLACK_BOT_TOKEN", "")
    if not app_token or not bot_token:
        raise Unavailable("Set local SLACK_APP_TOKEN and SLACK_BOT_TOKEN")
    lock = ProcessLock(args.state)
    api = LocalAPI(args.control_url, args.token_file)
    # Disable even connection-error retries for non-idempotent Web API calls.
    web = WebClient(token=bot_token, retry_handlers=[], timeout=10, logger=quiet)
    socket = None
    connector = None
    tasks = []
    try:
        bot = await asyncio.to_thread(web.auth_test)
        connector = Connector(api, SlackTransport(web), args.state, config["allowed"], bot["user_id"])
        principals = connector.principals()
        if any(p["workspace"] != bot["team_id"] for p in principals):
            raise Unavailable("Bot installation and configured workspace must match")
        # A returned SDK connect() is not proof of a live socket. Verify local
        # policy without acquiring an online lease or posting until fresh hello.
        connector.socket_closed()
        for principal in principals:
            await connector.call_api({"action": "list", "principal": principal})
        loop = asyncio.get_running_loop()
        pending = set()
        pending_lock = threading.RLock()
        socket_ready = asyncio.Event()
        refresh_tasks = set()

        async def lost_connection(generation):
            async with connector.lock:
                if generation != connector.connection_generation:
                    return
                connector.online = False
                for principal in principals:
                    try:
                        await connector.call_api({"action": "offline", "principal": principal})
                        if generation != connector.connection_generation:
                            return
                        for session in list(connector.sessions.values()):
                            if session["attachment"]["workspace"] == principal["workspace"] and session["attachment"]["channel"] == principal["channel"]:
                                await connector.offline_message(session["attachment"]["id"], principal)
                    except Exception:
                        pass

        def disconnected(*_):
            def mark():
                if connector.enabled:
                    connector.socket_closed()
                    socket_ready.clear()
                    for task in list(refresh_tasks):
                        task.cancel()
                    asyncio.create_task(lost_connection(connector.connection_generation))
            loop.call_soon_threadsafe(mark)

        def raw_message(raw):
            try:
                kind = json.loads(raw).get("type")
            except (ValueError, AttributeError):
                return
            if kind == "disconnect":
                disconnected()
            elif kind == "hello":
                def connected():
                    connector.socket_hello()
                    for task in list(refresh_tasks):
                        task.cancel()
                    socket_ready.set()
                loop.call_soon_threadsafe(connected)

        Client = fenced_socket_client(SocketModeClient, Connection, ConnectionState)
        socket = Client(app_token=app_token, web_client=web, auto_reconnect_enabled=True,
            logger=quiet, transport_lost=disconnected, on_message_listeners=[raw_message])

        def receive(client, request):
            # The SDK invokes listeners from worker threads. ACK synchronously,
            # before scheduling any authorization, journal, HTTP or Codex work.
            client.send_socket_mode_response(SocketModeResponse(envelope_id=request.envelope_id))
            envelope = {"type": request.type, "payload": request.payload, "envelope_id": request.envelope_id}
            async def acknowledged(_):
                pass
            with pending_lock:
                if connector.enabled and len(pending) < 256:
                    future = asyncio.run_coroutine_threadsafe(connector.envelope(envelope, acknowledged), loop)
                    pending.add(future)
                    def completed(done):
                        with pending_lock:
                            pending.discard(done)
                    future.add_done_callback(completed)
        socket.socket_mode_request_listeners.append(receive)
        # SDK handles disconnect/refresh_requested by apps.connections.open with
        # a fresh URL. No cached or persisted WebSocket URL/credential is reused.
        if stopped is None:
            stopped = asyncio.Event()
            for name in (signal.SIGINT, signal.SIGTERM):
                loop.add_signal_handler(name, stopped.set)
        await asyncio.to_thread(socket.connect)
        print("Banyan Slack connector started; awaiting Slack hello and Banyan synchronization (Ctrl-C to stop)", flush=True)
        announced = False

        async def observe(principal):
            nonlocal announced
            first = True
            delay = 1
            while connector.enabled:
                try:
                    await socket_ready.wait()
                    refresh = asyncio.create_task(connector.refresh(principal, first=first))
                    refresh_tasks.add(refresh)
                    try:
                        await refresh
                    finally:
                        refresh_tasks.discard(refresh)
                    if connector.socket_synchronized and connector.online and not announced:
                        announced = True
                        print("Banyan Slack connector synchronized", flush=True)
                    delay, first = 1, False
                except asyncio.CancelledError:
                    if not connector.enabled:
                        raise
                    first = True  # A new hello must not wait for an old long poll.
                except Denied:
                    connector.authorization_denied = True
                    connector.online = False
                    await asyncio.sleep(5)
                    first = True
                except Exception:
                    connector.online = False
                    async with connector.lock:
                        for session in list(connector.sessions.values()):
                            a = session["attachment"]
                            if a["workspace"] == principal["workspace"] and a["channel"] == principal["channel"]:
                                try:
                                    await connector.offline_message(a["id"], principal)
                                except Exception:
                                    pass
                    # Backoff only for network recovery, not state polling.
                    await asyncio.sleep(delay)
                    delay, first = min(delay * 2, 30), True
        tasks = [asyncio.create_task(observe(p)) for p in principals]
        await stopped.wait()
        await connector.stop()
        for future in list(pending):
            future.cancel()
    finally:
        if connector:
            connector.enabled = False  # Fence callbacks before socket teardown.
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        if socket:
            await asyncio.to_thread(socket.close)
        lock.close()


def main():
    parser = argparse.ArgumentParser(description="Outbound Slack interface to existing Banyan native Codex sessions")
    commands = parser.add_subparsers(dest="command", required=True)
    start = commands.add_parser("start", help="Run in foreground; Ctrl-C/SIGTERM stops callbacks and delivery")
    start.add_argument("--config", required=True, help="Local enabled/allowed policy JSON; contains no tokens")
    start.add_argument("--token-file", default=str(Path.home() / "Library/Application Support/Banyan/control-token"))
    start.add_argument("--control-url", default="http://127.0.0.1:7842")
    status = commands.add_parser("status", help="Inspect safe delivery statuses without credentials/content")
    reconcile = commands.add_parser("reconcile-post", help="Record the timestamp of an already posted uncertain message; never resend")
    reconcile.add_argument("--key", required=True)
    reconcile.add_argument("--ts", required=True)
    for command in (start, status, reconcile):
        command.add_argument("--state", default=str(Path.home() / "Library/Application Support/Banyan/slack-connector/state.json"))
    args = parser.parse_args()
    try:
        if args.command == "start":
            asyncio.run(run(args))
        else:
            from .connector import Journal
            lock = ProcessLock(args.state)
            try:
                journal = Journal(args.state)
                if args.command == "status":
                    print(json.dumps({group: {key: {k: v for k, v in value.items() if k in ("status", "channel", "root", "ts")}
                        for key, value in journal.data[group].items() if value.get("status") in ("uncertain", "sending", "retryable") or value.get("result", {}).get("status") == "uncertain"}
                        for group in ("incoming", "posts")}, indent=2))
                else:
                    post = journal.data["posts"].get(args.key)
                    if not post or post["status"] != "uncertain" or not re.fullmatch(r"[0-9]+[.][0-9]+", args.ts):
                        raise Unavailable("Only an uncertain post with an existing Slack timestamp can be reconciled")
                    journal.commit(lambda d: d["posts"][args.key].update(status="sent", ts=args.ts))
                    print("Existing Slack message recorded. No message or Codex action was submitted.")
            finally:
                lock.close()
    except KeyboardInterrupt:
        pass
    except Exception:
        # SDK exception representations can contain credentials or message text.
        print("Connector unavailable. Check local policy, journal, token files and setup documentation.", file=sys.stderr)
        sys.exit(1)
