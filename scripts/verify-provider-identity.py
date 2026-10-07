#!/usr/bin/env python3
"""Exercise installed Claude/OpenCode identity adapters against loopback inference.

Requires macOS, tmux, Node dependencies already installed by the provider, and
`swift build --product banyanctl`. All homes, config, model endpoints and tmux
sockets are disposable and private. No credentials or live Banyan socket are
used. Artifacts remain in the printed private directory for inspection.
"""
import argparse
import http.server
import importlib.util
import json
import os
import pathlib
import shlex
import shutil
import subprocess as S
import sys
import tempfile
import threading
import time
import uuid


def main():
    sys.dont_write_bytecode = True
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("provider", choices=["claude", "opencode"])
    parser.add_argument(
        "--executable",
        help="Installed provider executable (defaults to provider on PATH)",
    )
    parser.add_argument(
        "--unsupported-adapter",
        action="store_true",
        help="Report an unsupported version through a private wrapper; verify normal provider still runs",
    )
    parser.add_argument(
        "--disabled",
        action="store_true",
        help="Verify disabled adapters refuse without breaking normal launch",
    )
    parser.add_argument(
        "--custom-tui-config",
        action="store_true",
        help="Verify an explicit OpenCode TUI config remains untouched/ineligible",
    )
    args = parser.parse_args()
    if args.custom_tui_config and args.provider != "opencode":
        parser.error("--custom-tui-config requires opencode")
    provider = args.provider
    executable = shutil.which(args.executable or provider)
    tmux = shutil.which("tmux")
    if not executable or not tmux:
        parser.error("Installed provider and tmux are required")
    repo = pathlib.Path(__file__).resolve().parent.parent
    host = str(repo / ".build/debug/banyanctl")
    if not pathlib.Path(host).is_file():
        parser.error("Build banyanctl first: swift build --product banyanctl")
    root = pathlib.Path(tempfile.mkdtemp(prefix="banyan-provider-installed-"))
    root.chmod(0o700)
    print(root, flush=True)
    spec = importlib.util.spec_from_file_location(
        "loopback", repo / "scripts/verify-codex-integration.py"
    )
    H = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(H)

    class Model(http.server.BaseHTTPRequestHandler):

        def log_message(self, *a):
            pass

        def do_POST(self):
            data = json.loads(
                self.rfile.read(int(self.headers.get("Content-Length", "0")))
            )
            text = json.dumps(data)
            with (root / "requests.log").open("a") as f:
                f.write(self.path + " " + text + "\n")
            if "fixture:busy" in text:
                (root / "busy-arrived").touch()
                for _ in range(1000):
                    if (root / "release").exists():
                        break
                    time.sleep(0.05)
            if "count_tokens" in self.path:
                body = {"input_tokens": 10}
            elif "/messages" in self.path:
                message = {
                    "id": "msg_fixture",
                    "type": "message",
                    "role": "assistant",
                    "model": "claude-fixture",
                    "content": [{"type": "text", "text": "FIXTURE_READY"}],
                    "stop_reason": "end_turn",
                    "stop_sequence": None,
                    "usage": {"input_tokens": 10, "output_tokens": 4},
                }
                if data.get("stream"):
                    start = dict(
                        message,
                        content=[],
                        stop_reason=None,
                        usage={"input_tokens": 10, "output_tokens": 0},
                    )
                    events = [
                        ("message_start", {"type": "message_start", "message": start}),
                        (
                            "content_block_start",
                            {
                                "type": "content_block_start",
                                "index": 0,
                                "content_block": {"type": "text", "text": ""},
                            },
                        ),
                        (
                            "content_block_delta",
                            {
                                "type": "content_block_delta",
                                "index": 0,
                                "delta": {
                                    "type": "text_delta",
                                    "text": "FIXTURE_READY",
                                },
                            },
                        ),
                        (
                            "content_block_stop",
                            {"type": "content_block_stop", "index": 0},
                        ),
                        (
                            "message_delta",
                            {
                                "type": "message_delta",
                                "delta": {
                                    "stop_reason": "end_turn",
                                    "stop_sequence": None,
                                },
                                "usage": {"output_tokens": 4},
                            },
                        ),
                        ("message_stop", {"type": "message_stop"}),
                    ]
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream")
                    self.end_headers()
                    try:
                        for kind, event in events:
                            self.wfile.write(
                                (
                                    "event: "
                                    + kind
                                    + "\ndata: "
                                    + json.dumps(event)
                                    + "\n\n"
                                ).encode()
                            )
                            self.wfile.flush()
                    except BrokenPipeError:
                        pass
                    return
                body = message
            else:
                chunk = {
                    "id": "chatcmpl_fixture",
                    "object": "chat.completion.chunk",
                    "created": 0,
                    "model": "fixture-model",
                    "choices": [
                        {
                            "index": 0,
                            "delta": {"content": "FIXTURE_READY"},
                            "finish_reason": None,
                        }
                    ],
                }
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()
                try:
                    self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                    chunk["choices"][0] = {
                        "index": 0,
                        "delta": {},
                        "finish_reason": "stop",
                    }
                    self.wfile.write(
                        ("data: " + json.dumps(chunk) + "\n\ndata: [DONE]\n\n").encode()
                    )
                    self.wfile.flush()
                except BrokenPipeError:
                    pass
                return
            raw = json.dumps(body).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Model)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    disabled = args.disabled or args.custom_tui_config or args.unsupported_adapter
    provider_executable = executable
    if args.unsupported_adapter:
        wrapper = root / provider
        wrapper.write_text(
            '#!/bin/sh\nif [ "$1" = --version ]; then echo 0.0.0; exit 0; fi\nexec '
            + shlex.quote(executable)
            + ' "$@"\n'
        )
        wrapper.chmod(0o700)
        executable = str(wrapper)
    home = root / "home"
    work = root / "work"
    home.mkdir()
    work.mkdir()
    env = {
        "HOME": str(home),
        "PATH": os.environ["PATH"],
        "SHELL": "/bin/sh",
        "TERM": "xterm-256color",
        "LANG": "en_US.UTF-8",
        "NO_COLOR": "1",
        "BANYAN_PROCESS_HOST": host,
        "BANYAN_FIXTURE_ROOT": str(root),
        "OPENCODE_DISABLE_AUTOUPDATE": "true",
        "OPENCODE_DISABLE_MODELS_FETCH": "true",
        "XDG_CONFIG_HOME": str(home / ".config"),
        "XDG_DATA_HOME": str(home / ".local/share"),
        "XDG_CACHE_HOME": str(home / ".cache"),
        "CLAUDE_CONFIG_DIR": str(home / ".claude"),
        "ANTHROPIC_API_KEY": "fixture-key",
        "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{server.server_port}",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        "DISABLE_AUTOUPDATER": "1",
    }
    if provider == "claude":
        (home / ".claude").mkdir()
        (home / ".claude/.claude.json").write_text(
            json.dumps(
                {
                    "hasCompletedOnboarding": True,
                    "theme": "dark",
                    "projects": {str(work): {"hasTrustDialogAccepted": True}},
                }
            )
        )
        if disabled:
            (home / ".claude/settings.json").write_text(
                json.dumps({"disableAllHooks": True})
            )
        custom = root / "custom-claude"
        (custom / ".claude-plugin").mkdir(parents=True)
        (custom / "hooks").mkdir()
        (custom / ".claude-plugin/plugin.json").write_text(
            json.dumps({"name": "fixture-custom", "version": "1.0.0"})
        )
        (custom / "hooks/hooks.json").write_text(
            json.dumps({"modules": ["./custom.mjs"]})
        )
        (custom / "hooks/custom.mjs").write_text(
            'export function register(on){on("session.start",async($,e,next)=>{const root=await $.env.get("BANYAN_FIXTURE_ROOT");await $.fs.write(root+"/custom-plugin.txt","active");return next(e)})}'
        )
        command = shlex.join(
            [
                executable,
                "--plugin-dir",
                str(custom),
                "--model",
                "claude-sonnet-4-6",
                "fixture:first",
            ]
        )
    else:
        config = home / ".config/opencode"
        config.mkdir(parents=True)
        (config / "opencode.json").write_text(
            json.dumps(
                {
                    "provider": {
                        "fixture": {
                            "npm": "@ai-sdk/openai-compatible",
                            "name": "Fixture",
                            "options": {
                                "baseURL": f"http://127.0.0.1:{server.server_port}/v1",
                                "apiKey": "fixture-key",
                            },
                            "models": {
                                "fixture-model": {
                                    "name": "fixture-model",
                                    "limit": {"context": 10000, "output": 1000},
                                }
                            },
                        }
                    },
                    "model": "fixture/fixture-model",
                }
            )
        )
        plugin = root / "fixture.mjs"
        plugin.write_text(
            """import {watch,readFileSync,writeFileSync} from "node:fs";
 export default {id:"fixture.custom", async tui(api) {
 const root=process.env.BANYAN_FIXTURE_ROOT;
 const boot=async()=>{if(!api.state.ready)return; const a=await api.client.session.create({title:"Fixture A"}),b=await api.client.session.create({title:"Fixture B"});
 if(a.error||b.error)throw Error(JSON.stringify([a,b])); await new Promise(r=>setTimeout(r,500)); api.route.navigate("session",{sessionID:a.data.id});
 writeFileSync(root+"/diag.json",JSON.stringify({route:api.route.current,ready:api.state.ready,plugins:api.plugins.list(),info:api.state.session.get(a.data.id),status:await api.client.session.status()}));
 writeFileSync(root+"/sessions.json",JSON.stringify({a:a.data.id,b:b.data.id,pid:process.pid,leader:api.tuiConfig.leader_timeout})); };
 let started=false;
 const stop=api.event.on("sync",()=>{});
 const bootTimer=setInterval(()=>{if(!started&&api.state.ready){started=true;clearInterval(bootTimer);boot().catch(e=>writeFileSync(root+"/error",String(e)));}},100);
 let lastAction=0; const watcher=watch(root,async()=>{try{const c=JSON.parse(readFileSync(root+"/action.json","utf8"));if(c.serial<=lastAction)return;lastAction=c.serial;
 if(c.action==="switch") api.route.navigate("session",{sessionID:c.id});
 if(c.action==="busy") await api.client.session.promptAsync({sessionID:c.id,parts:[{type:"text",text:"fixture:busy"}],model:{providerID:"fixture",modelID:"fixture-model"}});
 writeFileSync(root+"/ack-"+c.serial,"ok");}catch(e){writeFileSync(root+"/error",String(e));}});
 api.lifecycle.onDispose(()=>{watcher.close();clearInterval(bootTimer);});
 }};"""
        )
        (config / "tui.json").write_text(
            json.dumps(
                {
                    "plugin": [str(plugin)],
                    "leader_timeout": 2345,
                    "plugin_enabled": {"banyan.session-identity": not args.disabled},
                }
            )
        )
        if args.custom_tui_config:
            env["OPENCODE_TUI_CONFIG"] = str(config / "tui.json")
            original_config = (config / "tui.json").read_bytes()
        command = shlex.join(["env", "OPENCODE_DISABLE_AUTOUPDATE=true", executable])
    sock = "banyan-provider-fixture-" + uuid.uuid4().hex

    def tm(*args):
        return S.run(
            [tmux, "-L", sock, "-f", "/dev/null", *args],
            env=env,
            capture_output=True,
            text=True,
            check=True,
            timeout=8,
        ).stdout.strip()

    def screen():
        text = tm("capture-pane", "-p", "-t", "fixture", "-S", "-70")
        (root / "screen.txt").write_text(text)
        return text

    def wait(fn, seconds=30):
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            if attached:
                try:
                    (root / "terminal.log").open("ab").write(
                        H.terminal_read(attached[1])
                    )
                except OSError:
                    pass
            value = fn()
            if value:
                return value
            time.sleep(0.1)
        raise RuntimeError("Timeout: " + screen())

    def getpid():
        if provider == "opencode":
            return json.loads((root / "sessions.json").read_text())["pid"]
        rows = S.run(
            ["/bin/ps", "-axo", "pid=,ppid=,args="],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.splitlines()
        children = {int(tm("display-message", "-p", "-t", "fixture", "#{pane_pid}"))}
        for _ in range(6):
            for line in rows:
                vals = line.strip().split(None, 2)
                if len(vals) == 3 and int(vals[1]) in children:
                    children.add(int(vals[0]))
        for line in rows:
            vals = line.strip().split(None, 2)
            if (
                len(vals) == 3
                and int(vals[0]) in children
                and (provider_executable in vals[2])
                and ("__process-host" not in vals[2])
            ):
                return int(vals[0])
        raise RuntimeError("No private Claude PID")

    def query(pid):
        r = S.run(
            [host, "__provider-identity", "query", str(pid), provider, str(work)],
            env=env,
            capture_output=True,
            text=True,
            timeout=6,
        )
        (root / "query.log").open("a").write(
            str(r.returncode) + " " + r.stdout + " " + r.stderr + "\n"
        )
        return json.loads(r.stdout) if r.returncode == 0 else None

    def helpers(pid):
        rows = S.run(
            ["/bin/ps", "-axo", "pid=,ppid=,args="],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.splitlines()
        descendants = {pid}
        for _ in range(8):
            for line in rows:
                cols = line.strip().split(None, 2)
                if len(cols) == 3 and int(cols[1]) in descendants:
                    descendants.add(int(cols[0]))
        return [
            int(cols[0])
            for line in rows
            if len((cols := line.strip().split(None, 2))) == 3
            and int(cols[0]) in descendants
            and ("__provider-identity wait " in cols[2])
        ]

    attached = None
    helper_pids = []
    evidence = {"provider": provider}
    try:
        tm(
            "new-session",
            "-d",
            "-s",
            "fixture",
            "-c",
            str(work),
            host,
            "__process-host",
            "--persistent",
            "/bin/sh",
            command,
        )
        attached = H.terminal_process(
            [tmux, "-L", sock, "attach-session", "-t", "fixture"], env, root
        )
        if provider == "claude":

            def ready():
                s = screen()
                if "trust this folder" in s and "[Banyan] Agent exited" not in s:
                    tm("send-keys", "-t", "fixture", "Down", "Enter")
                    time.sleep(0.4)
                if "Do you want to use this API key?" in s:
                    tm("send-keys", "-t", "fixture", "Up", "Enter")
                    time.sleep(0.5)
                return "FIXTURE_READY" in s

            wait(ready, 40)
        else:
            wait(lambda: (root / "sessions.json").exists(), 40)
        pid = getpid()
        print("pid", pid, flush=True)
        evidence["providerPID"] = pid
        if provider == "claude" and (not disabled):
            assert (root / "custom-plugin.txt").read_text() == "active"
        if args.custom_tui_config:
            assert (
                pathlib.Path(env["OPENCODE_TUI_CONFIG"]).read_bytes() == original_config
            )
        if disabled:
            assert query(pid) is None, "Disabled adapter accepted"
            assert (
                S.run(
                    ["/bin/ps", "-p", str(pid), "-o", "pid="], capture_output=True
                ).returncode
                == 0
            )
            evidence.update(
                adapterRefused=True,
                normalProviderLive=True,
                disabled=args.disabled,
                unsupportedVersion=args.unsupported_adapter,
                explicitTUIConfigPreserved=args.custom_tui_config,
            )
            print(
                "PASS disabled adapter refuses; normal provider remains live",
                flush=True,
            )
            sys.exit(0)
        first = wait(lambda: query(pid), 10)
        print("first", first, flush=True)
        if provider == "claude":
            tm("send-keys", "-t", "fixture", "-l", "/clear")
            tm("send-keys", "-t", "fixture", "Enter")
            time.sleep(0.5)
            tm("send-keys", "-t", "fixture", "-l", "fixture:second")
            tm("send-keys", "-t", "fixture", "Enter")
            wait(
                lambda: (answer := query(pid))
                and answer["id"] != first["id"]
                and "FIXTURE_READY" in screen(),
                30,
            )
        else:
            ids = json.loads((root / "sessions.json").read_text())
            assert ids["leader"] == 2345, ids
            (root / "action.json").write_text(
                json.dumps({"serial": 1, "action": "switch", "id": ids["b"]})
            )
            wait(lambda: (root / "ack-1").exists())
        second = wait(lambda: query(pid), 10)
        assert second["id"] != first["id"], second
        print("switched", second, flush=True)
        if provider == "claude":
            tm("send-keys", "-t", "fixture", "-l", "fixture:busy")
            tm("send-keys", "-t", "fixture", "Enter")
        else:
            (root / "action.json").write_text(
                json.dumps({"serial": 2, "action": "busy", "id": second["id"]})
            )
        wait(lambda: (root / "busy-arrived").exists(), 30)
        assert query(pid) is None, "Busy provider accepted"
        print("busy refused", flush=True)
        (root / "release").touch()
        wait(lambda: query(pid), 30)
        if provider == "claude":
            previous = second["id"]
            for _ in range(4):
                tm("send-keys", "-t", "fixture", "-l", "/clear")
                tm("send-keys", "-t", "fixture", "Enter")
                time.sleep(0.3)
                current = wait(lambda: query(pid), 10)
                assert (
                    current["id"] != previous
                ), "Current session getter stayed stale after /clear"
                previous = current["id"]
                wait(lambda: len(helpers(pid)) == 1, 10)
                assert len(helpers(pid)) == 1, "Helper accumulated after session switch"
            helper_pids = helpers(pid)
            assert len(helper_pids) == 1
        evidence.update(
            firstID=first["id"],
            switchedID=second["id"],
            busyRefused=True,
            recoveredAfterBusy=True,
            customPluginSettingsPreserved=True,
        )
        if provider == "claude":
            evidence.update(repeatedSwitches=4, liveHelperCount=len(helper_pids))
        print(
            "PASS live switched session, busy refusal, custom plugin/settings merge",
            flush=True,
        )
    finally:
        (root / "release").touch()
        if attached:
            try:
                os.close(attached[1])
            except OSError:
                pass
            H.stop(attached[0])
        S.run([tmux, "-L", sock, "kill-server"], env=env, capture_output=True)
        if helper_pids:
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline and any(
                (
                    S.run(["/bin/kill", "-0", str(pid)], capture_output=True).returncode
                    == 0
                    for pid in helper_pids
                )
            ):
                time.sleep(0.05)
            assert all(
                (
                    S.run(["/bin/kill", "-0", str(pid)], capture_output=True).returncode
                    != 0
                    for pid in helper_pids
                )
            ), "Identity helper survived provider exit"
            evidence["helperExitedWithProvider"] = True
            print(
                "PASS one helper across repeated switches; exited with private provider",
                flush=True,
            )
        server.shutdown()
        server.server_close()
        (root / "provider-identity-evidence.json").write_text(
            json.dumps(evidence, indent=2)
        )


if __name__ == "__main__":
    main()
