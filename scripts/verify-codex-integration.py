#!/usr/bin/env python3
"""Run the opt-in native Banyan test against real Codex and local Responses SSE.

No login files, API keys, external inference, or running Banyan/tmux are used.
The retained private artifact directory is printed before the run starts.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import shutil
import subprocess
import struct
import termios
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2))
    temporary.replace(path)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def private_environment(home):
    return {"HOME": str(home), "CODEX_HOME": str(home),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"), "TERM": "xterm-256color",
        "COLORTERM": "truecolor", "NO_COLOR": "1"}


def terminal_process(arguments, env, cwd):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    try:
        process = subprocess.Popen(arguments, env=env, cwd=cwd, stdin=slave, stdout=slave,
            stderr=slave, start_new_session=True)
    except BaseException:
        os.close(master)
        raise
    finally:
        os.close(slave)
    return process, master


def terminal_read(descriptor):
    if not select.select([descriptor], [], [], 0.1)[0]:
        return b""
    data = os.read(descriptor, 65536)
    if b"\x1b[6n" in data:
        os.write(descriptor, b"\x1b[1;1R")
    if b"\x1b]11;?" in data:
        os.write(descriptor, b"\x1b]11;rgb:0000/0000/0000\x1b\\")
    return data


def close_terminal(process, descriptor):
    # Give the interactive UI its normal exit action and drain its final paint
    # before closing the PTY. Otherwise a launcher can wait on a child blocked
    # flushing terminal output. Only the process created here is signalled.
    try:
        if process.poll() is None:
            os.write(descriptor, b"\x04")
            deadline = time.monotonic() + 3
            while process.poll() is None and time.monotonic() < deadline:
                try:
                    terminal_read(descriptor)
                except OSError:
                    break
    finally:
        os.close(descriptor)
        stop(process)


def tree_rss(pid):
    rows = []
    for row in subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss=,comm="], text=True).splitlines():
        child, parent, rss, command = row.split(None, 3)
        rows.append((int(child), int(parent), int(rss), Path(command).name))
    selected = {pid}
    while True:
        more = {child for child, parent, _, _ in rows if parent in selected}
        if more.issubset(selected):
            break
        selected.update(more)
    processes = [{"pid": child, "ppid": parent, "rssKiB": rss, "command": command}
                 for child, parent, rss, command in rows if child in selected]
    assert any(row["pid"] == pid for row in processes), "measured root exited"
    return {"rssKiB": sum(row["rssKiB"] for row in processes), "processes": processes}


def measure_idle(root, request, executable):
    """Same fresh idle-session count; sums only owned agent process trees."""
    launches = [json.loads(line) for line in (root / "launches.jsonl").read_text().splitlines()]
    server_pid = [item["pid"] for item in launches if item["argv"] == ["app-server", "--listen", "stdio://"]][-1]
    clients = []
    try:
        for index, cwd in enumerate(request["cwds"]):
            home = root / f"tui-{request['count']}-{index}"
            home.mkdir()
            config = (root / "codex-home" / "config.toml").read_text()
            (home / "config.toml").write_text(config + f'\n[projects.{json.dumps(cwd)}]\ntrust_level = "trusted"\n')
            process, descriptor = terminal_process([executable, "--no-daemon", "-C", cwd,
                "--sandbox", "read-only", "--ask-for-approval", "never"], private_environment(home), cwd)
            clients.append((process, descriptor))
            output = bytearray()
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                if process.poll() is not None:
                    raise RuntimeError(f"idle CLI exited: {process.returncode}")
                output.extend(terminal_read(descriptor))
                if b"fixture-model" in output and "›".encode() in output:
                    break
            else:
                raise RuntimeError("idle CLI did not render its composer")
            (root / f"tui-{request['count']}-{index}.log").write_bytes(output)
        time.sleep(2)
        samples = []
        for _ in range(3):
            native = tree_rss(server_pid)
            cli_trees = [tree_rss(process.pid) for process, _ in clients]
            samples.append({"native": native, "cli": cli_trees,
                "cliTotalRSSKiB": sum(tree["rssKiB"] for tree in cli_trees)})
            time.sleep(0.25)
        return {"count": request["count"], **samples[1], "samples": samples,
            "workload": "Fresh idle threads and fully initialized interactive CLIs, no inference/history; excludes Banyan UI and fixture provider."}
    finally:
        for process, descriptor in clients:
            close_terminal(process, descriptor)


def interactive_handoff(root, binding, executable):
    """Run Banyan's exact fallback command in a disposable PTY, then prompt it."""
    process, master = terminal_process(["/bin/sh", "-c", "exec " + binding["command"]],
        private_environment(binding["codexHome"]), binding["cwd"])
    output = bytearray()
    sent = False
    submitted = False
    typed_at = None
    try:
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f"CLI exited: {process.returncode}")
            data = terminal_read(master)
            if data:
                output.extend(data)
                plain = output.decode(errors="replace")
                if not sent and binding["readyText"] in plain:
                    os.write(master, b"\x1b[200~fixture:cli-handoff\x1b[201~")
                    sent = True
                    typed_at = time.monotonic()
            # Submit after the paste has been painted. Codex's paste detector
            # intentionally treats a newline in the same burst as draft text.
            if sent and not submitted and time.monotonic() - typed_at > 0.5:
                os.write(master, b"\r")
                submitted = True
            # Verify completed inference in the authoritative rollout as well
            # as the PTY. A painted history item alone does not prove a turn.
            for file in (Path(binding["codexHome"]) / "sessions").rglob("*.jsonl"):
                if binding["threadID"] not in file.name:
                    continue
                rows = [json.loads(line) for line in file.read_text().splitlines()]
                asks = [i for i, row in enumerate(rows) if "fixture:cli-handoff" in json.dumps(row)]
                if asks and any(row.get("payload", {}).get("type") == "task_complete"
                                for row in rows[max(asks) + 1:]):
                    assert sent
                    return {"completed": True, "threadID": binding["threadID"], "pid": process.pid}
        raise RuntimeError("CLI handoff prompt did not complete; inspect cli-pty.log")
    finally:
        (root / "cli-pty.log").write_bytes(output)
        close_terminal(process, master)


def verify_settings(root):
    contexts = []
    for file in (root / "codex-home" / "sessions").rglob("*.jsonl"):
        for line in file.read_text().splitlines():
            row = json.loads(line)
            if row.get("type") != "turn_context":
                continue
            value = row["payload"]
            contexts.append({key: value.get(key) for key in
                ["turn_id", "cwd", "model", "approval_policy", "sandbox_policy", "effort"]})
    for model, approval, sandbox, effort in [
        ("fixture-model", "untrusted", "workspace-write", "low"),
        ("fixture-second", "never", "read-only", "high")
    ]:
        turns = [context for context in contexts if context["model"] == model]
        assert len(turns) >= 3, f"missing actual turn contexts for {model}"
        assert all(context["approval_policy"] == approval and
                   context["sandbox_policy"]["type"] == sandbox and
                   context["effort"] == effort for context in turns), turns
    write_json(root / "settings-evidence.json", contexts)


class Responses(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        try:
            assert self.path == "/v1/responses", self.path
            # Codex can compress large requests; explicitly disable compression
            # in the private provider config rather than decoding ambiguously.
            assert self.headers.get("Content-Encoding", "identity") == "identity"
            request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            with self.server.lock:
                index = self.server.next_id
                self.server.next_id += 1
            (self.server.root / f"request-{index}.json").write_text(json.dumps(request, indent=2))
            history = request["input"]
            last = max(i for i, item in enumerate(history)
                       if item.get("role") == "user" and "fixture:" in json.dumps(item))
            prompt = json.dumps(history[last])
            after = history[last + 1:]
            scenario = next((s for s in ["approve", "decline", "question", "steer", "interrupt", "second"]
                             if f"fixture:{s}" in prompt), "hello")
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.close_connection = True

            def event(kind, **fields):
                self.wfile.write(("data: " + json.dumps({"type": kind, **fields}) + "\n\n").encode())
                self.wfile.flush()

            response_id = f"fixture-response-{index}"
            event("response.created", response={"id": response_id})
            if scenario in ["steer", "interrupt"]:
                event("response.output_item.added", output_index=0, item={
                    "id": f"message-{index}", "type": "message", "role": "assistant", "content": []})
                event("response.output_text.delta", item_id=f"message-{index}", output_index=0,
                      content_index=0, delta="WORKING")
                # The test releases a steered stream after the RPC is accepted;
                # interruption instead cancels it. Never block indefinitely.
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline and not (self.server.root / "release-steer").exists():
                    time.sleep(0.02)
            if scenario in ["approve", "decline", "question"] and not any(
                    item.get("type") == "function_call_output" for item in after):
                if scenario == "question":
                    name = "request_user_input"
                    arguments = {"questions": [{"id": "choice", "header": "Choice",
                        "question": "Choose a fixture answer", "options": [
                            {"label": "Alpha", "description": "First answer"},
                            {"label": "Beta", "description": "Second answer"}]}]}
                else:
                    name = "exec_command"
                    arguments = {"cmd": f"printf APPROVED > {scenario}-proof.txt", "login": False}
                event("response.output_item.done", output_index=0, item={
                    "id": f"tool-{index}", "type": "function_call", "call_id": f"call-{index}",
                    "name": name, "arguments": json.dumps(arguments)})
            else:
                text = f"FIXTURE_{scenario.upper()}_OK"
                event("response.output_item.added", output_index=0, item={
                    "id": f"reply-{index}", "type": "message", "role": "assistant", "content": []})
                event("response.output_text.delta", item_id=f"reply-{index}", output_index=0,
                      content_index=0, delta=text)
                event("response.output_item.done", output_index=0, item={
                    "id": f"reply-{index}", "type": "message", "role": "assistant",
                    "content": [{"type": "output_text", "text": text}]})
            event("response.completed", response={"id": response_id,
                "usage": {"input_tokens": 10, "output_tokens": 10, "total_tokens": 20}})
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when the real agent interrupts an inference stream.
        except Exception as error:
            with (self.server.root / "provider-errors.log").open("a") as log:
                log.write(repr(error) + "\n")
            raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default="codex")
    parser.add_argument("--unload-timeout", type=int, default=125,
                        help="Seconds allowed for the server's version-dependent idle unload")
    args = parser.parse_args()
    executable = shutil.which(args.codex)
    if not executable:
        parser.error("Codex executable not found")
    root = Path(tempfile.mkdtemp(prefix="banyan-codex-integrated-"))
    root.chmod(0o700)
    home = root / "codex-home"
    home.mkdir()
    server = ThreadingHTTPServer(("127.0.0.1", 0), Responses)
    server.daemon_threads = True
    server.root, server.lock, server.next_id = root, threading.Lock(), 1
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    (home / "config.toml").write_text(f'''model_provider = "loopback"
model = "fixture-model"
[features]
enable_request_compression = false
default_mode_request_user_input = true
plugins = false
[model_providers.loopback]
name = "Private Responses fixture"
base_url = "http://127.0.0.1:{server.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
[model_providers.loopback_second]
name = "Private independent Responses fixture"
base_url = "http://127.0.0.1:{server.server_port}/v1"
wire_api = "responses"
requires_openai_auth = false
supports_websockets = false
request_max_retries = 0
stream_max_retries = 0
''')
    # A transparent exec wrapper records only processes launched by this test.
    wrapper = root / "codex-fixture"
    wrapper.write_text("#!/usr/bin/python3\nimport os, json\n"
        f"with open({str(root / 'launches.jsonl')!r}, 'a') as f: "
        "f.write(json.dumps({'pid':os.getpid(),'argv':os.sys.argv[1:]})+'\\n')\n"
        f"os.execv({executable!r}, [{executable!r}] + os.sys.argv[1:])\n")
    wrapper.chmod(0o700)
    manifest = {"root": str(root), "codex": executable, "providerPort": server.server_port,
        "command": ["swift", "test", "--filter", "installedCodexNativeIntegration"],
        "cleanup": "Test reaps its own App Server children. Remove this private directory after evidence review."}
    manifest["codexVersion"] = subprocess.check_output([executable, "--version"],
        env=private_environment(home), text=True).strip()
    (root / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(root, flush=True)
    # Build/test uses the developer toolchain; only the Codex child receives the
    # deliberately small environment constructed by the Swift test.
    env = dict(os.environ, BANYAN_CODEX_INTEGRATION_ROOT=str(root),
               BANYAN_CODEX_INTEGRATION_EXECUTABLE=str(wrapper),
               BANYAN_CODEX_UNLOAD_TIMEOUT=str(args.unload_timeout), NO_COLOR="1")
    for key in ["CLICOLOR_FORCE", "FORCE_COLOR", "GH_FORCE_TTY"]:
        env.pop(key, None)
    try:
        process = subprocess.Popen(manifest["command"], env=env)
        while process.poll() is None:
            handoff = root / "handoff.json"
            result_path = root / "cli-result.json"
            if handoff.exists() and not result_path.exists():
                try:
                    result = interactive_handoff(root, json.loads(handoff.read_text()), executable)
                except Exception as error:
                    result = {"completed": False, "error": str(error)}
                write_json(result_path, result)
            for count in [1, 2, 4]:
                request_path = root / f"memory-request-{count}.json"
                result_path = root / f"memory-result-{count}.json"
                if request_path.exists() and not result_path.exists():
                    try:
                        result = measure_idle(root, json.loads(request_path.read_text()), executable)
                    except Exception as error:
                        result = {"error": str(error)}
                    write_json(result_path, result)
            time.sleep(0.05)
        manifest["testExitCode"] = process.returncode
        if process.returncode == 0:
            verify_settings(root)
        cleanup = subprocess.run(["/usr/sbin/lsof", "-t", "+D", str(root)],
            text=True, capture_output=True, check=False)
        manifest["openArtifactPIDsAfterTest"] = cleanup.stdout.split()
        if manifest["openArtifactPIDsAfterTest"]:
            manifest["cleanupError"] = "Owned fixture store still has open files; inspect before removing artifacts."
        (root / "manifest.json").write_text(json.dumps(manifest, indent=2))
        return process.returncode or (1 if manifest["openArtifactPIDsAfterTest"] else 0)
    finally:
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    raise SystemExit(main())
