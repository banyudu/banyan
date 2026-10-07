#!/usr/bin/env python3
"""Verify installed Codex deep suspend with no credentials or external inference.

Reuses the native integration Responses fixture. Every CLI, pane and home is
private; the live Banyan app and its tmux socket are never contacted.
"""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default="codex")
    args = parser.parse_args()
    executable = shutil.which(args.codex)
    tmux = shutil.which("tmux")
    if not executable or not tmux:
        parser.error("Installed Codex and tmux are required")
    source = Path(__file__).with_name("verify-codex-integration.py")
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("codex_loopback", source)
    harness = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(harness)
    root = Path(tempfile.mkdtemp(prefix="banyan-deep-installed-"))
    root.chmod(0o700)
    home = root / "home"
    codex_home = home / ".codex"
    codex_home.mkdir(parents=True)
    server = harness.ThreadingHTTPServer(("127.0.0.1", 0), harness.Responses)
    server.daemon_threads = True
    server.root, server.lock, server.next_id = root, threading.Lock(), 1
    threading.Thread(target=server.serve_forever, daemon=True).start()
    (codex_home / "config.toml").write_text(
        f"""check_for_update_on_startup = false
model_provider = "loopback"
model = "fixture-model"
[features]
enable_request_compression = false
plugins = false
[model_providers.loopback]
name = "Private Responses fixture"
base_url = "http://127.0.0.1:{server.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
"""
    )
    (codex_home / "deep-fixture.config.toml").write_text(
        (codex_home / "config.toml").read_text()
    )
    env = dict(
        os.environ,
        BANYAN_CODEX_DEEP_ROOT=str(root),
        BANYAN_CODEX_DEEP_EXECUTABLE=executable,
        NO_COLOR="1",
    )
    for key in ("CLICOLOR_FORCE", "FORCE_COLOR", "GH_FORCE_TTY"):
        env.pop(key, None)
    print(root, flush=True)
    process = subprocess.Popen(
        ["swift", "test", "--filter", "installedCodexDeepSuspendAndExactResume"],
        env=env,
    )
    attached = None
    socket = None
    serial = 0
    terminal_log = (root / "terminal.log").open("ab")
    private_env = harness.private_environment(home)
    private_env["CODEX_HOME"] = str(codex_home)
    private_env["LANG"] = "en_US.UTF-8"
    try:
        while process.poll() is None:
            request_path = root / "terminal-request.json"
            request = (
                json.loads(request_path.read_text()) if request_path.exists() else None
            )
            if request and request["serial"] != serial:
                socket = request["socket"]
                assert socket.startswith("banyan-deep-installed-")
                if attached:
                    subprocess.run(
                        [tmux, "-L", socket, "detach-client", "-s", request["session"]],
                        env=private_env,
                        check=True,
                        capture_output=True,
                    )
                    attached[0].wait(timeout=5)
                    os.close(attached[1])
                    attached = None
                if request["attached"]:
                    attached = harness.terminal_process(
                        [
                            tmux,
                            "-L",
                            socket,
                            "attach-session",
                            "-t",
                            request["session"],
                        ],
                        private_env,
                        root,
                    )
                serial = request["serial"]
                (root / f"terminal-ack-{serial}").touch()
            if attached:
                try:
                    terminal_log.write(harness.terminal_read(attached[1]))
                    terminal_log.flush()
                except OSError:
                    pass
            else:
                time.sleep(0.05)
        result = process.wait()
        print(
            f"Installed deep-suspend test exit={result}; evidence: {root / 'deep-suspend-evidence.json'}",
            flush=True,
        )
        return result
    finally:
        terminal_log.close()
        if attached:
            os.close(attached[1])
            harness.stop(attached[0])
        if socket:
            subprocess.run(
                [tmux, "-L", socket, "kill-server"],
                env=private_env,
                capture_output=True,
            )
        harness.stop(process)
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    raise SystemExit(main())
