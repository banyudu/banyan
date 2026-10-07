"""Lifecycle adapter for pinned slack_sdk 3.45.0's builtin SocketModeClient.

The builtin Connection invokes close before disconnecting its socket, and the
client reconnects before notifying on_close listeners. Capture the originating
connection so we can fence immediately and ignore a retired connection's close.
The SDK retains URL issuance, acknowledgments, refresh and reconnect policy.
"""


def fenced_socket_client(base, connection_type, state_type):
    class FencedSocketModeClient(base):
        def __init__(self, *, transport_lost, **kwargs):
            self.transport_lost = transport_lost
            super().__init__(**kwargs)

        def connect(self):
            # This small construction override follows the pinned builtin
            # connect implementation; callbacks are bound BEFORE reads start.
            old = self.current_session
            old_state = self.current_session_state
            if self.wss_uri is None:
                self.wss_uri = self.issue_new_wss_url()
            connection = connection_type(url=self.wss_uri, logger=self.logger,
                ping_interval=self.ping_interval, trace_enabled=self.trace_enabled,
                all_message_trace_enabled=self.all_message_trace_enabled,
                ping_pong_trace_enabled=self.ping_pong_trace_enabled,
                receive_buffer_size=self.receive_buffer_size, proxy=self.proxy,
                proxy_headers=self.proxy_headers, ssl_context=self.web_client.ssl)
            connection.on_message_listener = lambda message: self._source_message(connection, message)
            connection.on_error_listener = lambda error: self._source_error(connection, error)
            connection.on_close_listener = lambda code, reason=None: self._source_close(connection, code, reason)
            connection.connect()
            if old_state is not None:
                old_state.terminated = True
            if old is not None:
                old.close()
            self.current_session = connection
            self.current_session_state = state_type()
            self.auto_reconnect_enabled = self.default_auto_reconnect_enabled
            if not self.current_app_monitor_started:
                self.current_app_monitor_started = True
                self.current_app_monitor.start()

        def _source_message(self, connection, message):
            if connection is self.current_session:
                super()._on_message(message)

        def _source_error(self, connection, error):
            if connection is self.current_session:
                self.transport_lost()
                super()._on_error(error)

        def _source_close(self, connection, code, reason):
            if connection is not self.current_session:
                return
            # Invalidate BEFORE any SDK URL issuance/connect can block. Closing
            # the source also lets the SDK see that it really needs a fresh URL.
            self.transport_lost()
            connection.disconnect()
            super()._on_close(code, reason)

    return FencedSocketModeClient
