#!/usr/bin/env python3
"""No network: exercise runtime adapter before/after a held SDK reconnect."""
import asyncio
from contextlib import ExitStack, redirect_stdout
import io
import json
import logging
import os
from pathlib import Path
import sys
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from banyan_slack.socket_adapter import fenced_socket_client


class Connection:
    def __init__(self, **kwargs):
        self.active = False
        self.session_id = "synthetic-session"
        self.on_message_listener = self.on_error_listener = self.on_close_listener = None
    def connect(self):
        self.active = True
    def close(self):
        self.active = False
    disconnect = close
    def is_active(self):
        return self.active
    def check_state(self):
        pass


class State:
    def __init__(self):
        self.terminated = False


class PinnedSDKShape:
    """Faithful ordering of the pinned builtin's relevant lifecycle methods."""
    def __init__(self, **kwargs):
        self.current_session = None
        self.current_session_state = State()
        self.wss_uri = None
        self.logger = None
        self.ping_interval = 5
        self.trace_enabled = self.all_message_trace_enabled = self.ping_pong_trace_enabled = False
        self.receive_buffer_size = 1024
        self.proxy = self.proxy_headers = None
        self.web_client = SimpleNamespace(ssl=None)
        self.default_auto_reconnect_enabled = self.auto_reconnect_enabled = True
        self.current_app_monitor_started = False
        self.current_app_monitor = SimpleNamespace(start=lambda: None)
        self.messages = []
        self.entered = threading.Event()
        self.release = threading.Event()
        self.hold = False
        self.urls = 0
    def issue_new_wss_url(self):
        self.urls += 1
        if self.hold:
            self.entered.set()
            self.release.wait(3)
        return f"wss://fixture.invalid/{self.urls}"
    def connect_to_new_endpoint(self, force=False):
        if force or not self.current_session.is_active():
            self.wss_uri = self.issue_new_wss_url()
            self.connect()
    def _on_close(self, code, reason):
        # SDK reconnects FIRST, then invokes its public close listeners.
        if self.auto_reconnect_enabled:
            self.connect_to_new_endpoint()
    def _on_error(self, error):
        pass
    def _on_message(self, raw):
        self.messages.append(json.loads(raw))


class AdapterTests(unittest.TestCase):
    def test_clean_close_fences_before_held_reconnect_and_stale_close_does_not_fence_fresh_hello(self):
        lost = []
        Client = fenced_socket_client(PinnedSDKShape, Connection, State)
        client = Client(transport_lost=lambda: lost.append(True))
        client.connect()
        old = client.current_session
        client.hold = True
        closing = threading.Thread(target=old.on_close_listener, args=(1000, "clean close"))
        closing.start()
        try:
            self.assertTrue(client.entered.wait(1), "Reconnect did not start")
            self.assertEqual(lost, [True], "Unavailable fence must precede blocked reconnect")
            self.assertFalse(old.is_active())
            client.release.set()
            closing.join(2)
            self.assertFalse(closing.is_alive())
            fresh = client.current_session
            fresh.on_message_listener('{"type":"hello"}')
            old.on_close_listener(1000, "delayed retired close")
            old.on_message_listener('{"type":"hello"}')
            self.assertEqual(lost, [True])
            self.assertEqual(client.messages, [{"type": "hello"}])
            self.assertEqual(client.urls, 2)
        finally:
            client.release.set()
            closing.join(2)

    def test_current_transport_error_fences_and_retired_errors_are_ignored(self):
        lost = []
        Client = fenced_socket_client(PinnedSDKShape, Connection, State)
        client = Client(transport_lost=lambda: lost.append(True))
        client.connect()
        old = client.current_session
        old.on_error_listener(RuntimeError("synthetic"))
        self.assertEqual(lost, [True])
        client.wss_uri = None
        client.connect()
        old.on_error_listener(RuntimeError("retired"))
        self.assertEqual(lost, [True])


class InstalledSDKAdapterTests(unittest.TestCase):
    def test_pinned_sdk_clean_close_reconnect_order_with_fake_connections(self):
        try:
            from slack_sdk import WebClient
            from slack_sdk.socket_mode import SocketModeClient
            from slack_sdk.socket_mode.builtin.client import ConnectionState
        except ImportError:
            self.skipTest("Optional pinned SDK check; run with connector venv")
        import logging
        quiet = logging.getLogger("banyan.fixture.sdk")
        quiet.disabled = True
        lost, received = [], []
        Client = fenced_socket_client(SocketModeClient, Connection, ConnectionState)
        client = Client(app_token="synthetic-local-app", web_client=WebClient(token="synthetic-local-bot", retry_handlers=[], logger=quiet),
            transport_lost=lambda: lost.append(True), logger=quiet, on_message_listeners=[received.append])
        # No background SDK reader/monitor or network is needed for these exact
        # builtin close/reconnect methods; all Connection instances are fakes.
        client.closed = True  # process_messages loops until this fence is set.
        client.current_session_runner.shutdown()
        client.message_processor.shutdown()
        client.closed = False
        client.current_app_monitor_started = True
        entered, release = threading.Event(), threading.Event()
        issued = []
        def issue():
            issued.append(True)
            if len(issued) > 1:
                entered.set()
                release.wait(3)
            return "wss://fixture.invalid/offline"
        client.issue_new_wss_url = issue
        closing = None
        try:
            client.connect()
            old = client.current_session
            closing = threading.Thread(target=old.on_close_listener, args=(1000, "clean close"))
            closing.start()
            self.assertTrue(entered.wait(1))
            self.assertEqual(lost, [True])
            release.set()
            closing.join(2)
            self.assertFalse(closing.is_alive())
            client.current_session.on_message_listener('{"type":"hello"}')
            old.on_close_listener(1000, "retired")
            self.assertEqual(lost, [True])
            self.assertEqual(received, ['{"type":"hello"}'])
            self.assertEqual(len(issued), 2)
            # Exercise the ACTUAL pinned heartbeat monitor path, which closes
            # without any on_close/error notification before refreshing URL.
            entered.clear()
            release.clear()
            client.current_session.disconnect()
            closing = threading.Thread(target=client._monitor_current_session)
            closing.start()
            self.assertTrue(entered.wait(1))
            self.assertEqual(lost, [True, True])
            release.set()
            closing.join(2)
            self.assertFalse(closing.is_alive())
            self.assertEqual(len(issued), 3)
        finally:
            release.set()
            if closing:
                closing.join(2)
            client.close()


class RuntimeStartupTests(unittest.IsolatedAsyncioTestCase):
    async def test_failed_initial_connect_stays_offline_until_reconnect_hello_and_sync(self):
        try:
            from slack_sdk.socket_mode import SocketModeClient
        except ImportError:
            self.skipTest("Optional pinned SDK check; run with connector venv")
        from banyan_slack import runtime
        real_connector = runtime.Connector
        captured, calls, output = {}, [], io.StringIO()
        stopped, synced, events = asyncio.Event(), asyncio.Event(), asyncio.Event()
        sync_allowed = asyncio.Event()
        async def until(predicate, timeout=2):
            async def wait():
                while not predicate():
                    await asyncio.sleep(0.01)
            await asyncio.wait_for(wait(), timeout)
        class API:
            def __init__(self, *args):
                pass
            async def call(self, body):
                calls.append(body["action"])
                if body["action"] == "sync":
                    await sync_allowed.wait()
                    synced.set()
                    return {"sessions": [], "events": [], "epoch": "fixture", "cursor": 0, "refresh": True}
                if body["action"] == "events":
                    await events.wait()
                return {"sessions": []}
        class Web:
            ssl = None
            def __init__(self, **kwargs):
                pass
            def auth_test(self):
                return {"user_id": "FIXTURE_BOT", "team_id": "FIXTURE_WORKSPACE"}
        class InitialFailure(Connection):
            attempts = 0
            def connect(self):
                type(self).attempts += 1
                # The actual Connection catches failures and returns inactive.
                self.active = type(self).attempts > 1
        def make_connector(*args, **kwargs):
            captured["connector"] = real_connector(*args, **kwargs)
            return captured["connector"]
        def factory(base, _, state):
            wrapped = fenced_socket_client(base, InitialFailure, state)
            class Client(wrapped):
                def __init__(self, **kwargs):
                    super().__init__(**kwargs)
                    # No actual readers or monitor threads in this fixture.
                    self.closed = True
                    self.current_session_runner.shutdown()
                    self.message_processor.shutdown()
                    self.closed = False
                    self.current_app_monitor_started = True
                    self.issue_new_wss_url = lambda: "wss://fixture.invalid/offline"
                    captured["client"] = self
            return Client
        with tempfile.TemporaryDirectory() as directory, ExitStack() as stack:
            config = Path(directory) / "config.json"
            config.write_text(json.dumps({"enabled": True, "allowed": [{"workspace": "FIXTURE_WORKSPACE", "channel": "FIXTURE_CHANNEL", "user": "FIXTURE_USER"}]}))
            args = SimpleNamespace(config=str(config), state=str(Path(directory) / "state.json"), control_url="http://127.0.0.1:1", token_file=str(Path(directory) / "token"))
            stack.enter_context(patch.dict(os.environ, {"SLACK_APP_TOKEN": "synthetic-local-app", "SLACK_BOT_TOKEN": "synthetic-local-bot"}))
            stack.enter_context(patch("slack_sdk.WebClient", Web))
            stack.enter_context(patch("banyan_slack.socket_adapter.fenced_socket_client", factory))
            stack.enter_context(patch.object(runtime, "LocalAPI", API))
            stack.enter_context(patch.object(runtime, "Connector", make_connector))
            stack.enter_context(redirect_stdout(output))
            task = asyncio.create_task(runtime.run(args, stopped=stopped))
            closing = None
            release = threading.Event()
            try:
                await until(lambda: "client" in captured and "awaiting Slack hello" in output.getvalue(), 4)
                connector, client = captured["connector"], captured["client"]
                self.assertFalse(client.is_connected())
                self.assertFalse(connector.online)
                self.assertFalse(connector.socket_synchronized)
                self.assertEqual(calls, ["list"])
                self.assertNotIn("synchronized", output.getvalue())
                await asyncio.to_thread(client.connect_to_new_endpoint)
                self.assertTrue(client.is_connected())
                self.assertFalse(connector.online, "Active socket alone cannot acquire the online lease")
                client.current_session.on_message_listener('{"type":"hello"}')
                await asyncio.sleep(0.02)
                self.assertFalse(connector.online, "Hello must wait for authoritative refresh")
                sync_allowed.set()
                await asyncio.wait_for(synced.wait(), 2)
                await until(lambda: connector.online and "connector synchronized" in output.getvalue())
                self.assertTrue(connector.socket_synchronized)
                self.assertIn("connector synchronized", output.getvalue())
                entered = threading.Event()
                old = client.current_session
                def held_url():
                    entered.set()
                    release.wait(3)
                    return "wss://fixture.invalid/refreshed"
                client.issue_new_wss_url = held_url
                closing = threading.Thread(target=old.on_close_listener, args=(1000, "clean close"))
                closing.start()
                self.assertTrue(await asyncio.to_thread(entered.wait, 1))
                await asyncio.sleep(0.02)
                self.assertFalse(connector.socket_connected)
                self.assertFalse(connector.socket_synchronized)
                self.assertFalse(connector.online)
                release.set()
                await asyncio.to_thread(closing.join, 2)
                self.assertFalse(closing.is_alive())
                self.assertFalse(connector.online, "Reconnect must await a new hello")
                client.current_session.on_message_listener('{"type":"hello"}')
                await until(lambda: connector.online)
                old.on_close_listener(1000, "retired close after fresh hello")
                await asyncio.sleep(0.02)
                self.assertTrue(connector.online)
            finally:
                release.set()
                if closing:
                    await asyncio.to_thread(closing.join, 2)
                stopped.set()
                sync_allowed.set()
                await asyncio.wait_for(task, 3)


if __name__ == "__main__":
    unittest.main()
