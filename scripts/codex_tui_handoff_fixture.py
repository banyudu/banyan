"""Private interactive tmux driver for verify-codex-integration.py --tui-handoff.

Only this fixture's unique socket and newly created PTY/processes are touched.
The Swift test performs the actual handoff validation and real RPC assertions.
"""
import json
import os
import shutil
import subprocess
import time


def drive(root, request, fixture, finished):
    tmux = shutil.which("tmux")
    if not tmux:
        raise RuntimeError("tmux is required")
    socket, name = request["socket"], request["session"]
    assert socket.startswith("banyan-handoff-test-")
    env = fixture.private_environment(request["codexHome"])
    command = [tmux, "-L", socket]
    process = descriptor = None
    output = bytearray()
    try:
        subprocess.run(command + ["-f", "/dev/null", "new-session", "-d", "-s", name,
            "-x", "120", "-y", "40", "-c", request["cwd"],
            "/bin/sh", "-c", "exec " + request["command"]], env=env, check=True)
        process, descriptor = fixture.terminal_process(command + ["attach-session", "-t", name], env, request["cwd"])
        ready = False
        handled = 0
        deadline = time.monotonic() + 100
        while not finished.is_set() and time.monotonic() < deadline:
            try:
                data = fixture.terminal_read(descriptor)
                output.extend(data)
            except OSError:
                data = b""
            if not ready and b"FIXTURE_HELLO_OK" in output:
                fixture.write_json(root / "legacy-ready.json", {"ready": True})
                ready = True
            action_path = root / "legacy-action.json"
            if action_path.exists():
                action = json.loads(action_path.read_text())
                if action["sequence"] > handled:
                    handled = action["sequence"]
                    if action["action"] == "prompt":
                        text = action["text"].encode()
                        os.write(descriptor, b"\x1b[200~" + text + b"\x1b[201~")
                        time.sleep(0.5)
                        os.write(descriptor, b"\r")
                    elif action["action"] == "answer":
                        os.write(descriptor, b"\r")
                        time.sleep(0.5)
                        os.write(descriptor, b"\r")
                    elif action["action"] == "quit":
                        # The user action occurs only after Swift has armed
                        # remain-on-exit. No signal/kill is used for handoff.
                        os.write(descriptor, b"/quit")
                        time.sleep(0.5)
                        os.write(descriptor, b"\r")
                    else:
                        raise RuntimeError("Unknown private fixture action")
                    fixture.write_json(root / "legacy-action-done.json", {"sequence": handled})
            time.sleep(0.02)
        if not finished.is_set():
            raise RuntimeError("Private handoff fixture timed out")
    finally:
        (root / "legacy-pty.log").write_bytes(output)
        # Cleanup is confined to the unique disposable server. A test failure
        # may leave its own CLI running; no live user/worker socket is reachable.
        subprocess.run(command + ["kill-server"], env=env, capture_output=True)
        if process is not None:
            fixture.close_terminal(process, descriptor)
