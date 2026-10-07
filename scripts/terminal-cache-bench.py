#!/usr/bin/env python3
"""Sample the opt-in private 24-session fixture; never attaches to the live app.

Usage: swift test --filter terminalViewCacheMemoryWorkload  # build first
       python3 scripts/terminal-cache-bench.py --cache-limit 24 --output /tmp/terminal-cache-before
       python3 scripts/terminal-cache-bench.py --output /tmp/terminal-cache-after
Raw heap/vmmap output stays local; publish only aggregate fixture measurements.
"""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--cache-limit", type=int, default=4,
                        help="24 reproduces retention of every fixture; default: 4")
    parser.add_argument("--banyanctl", type=Path,
                        help="CLI for the read-only perf report; defaults to the local build product")
    args = parser.parse_args()
    root = args.output.resolve()
    root.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, BANYAN_TERMINAL_CACHE_BENCH_DIR=str(root),
               BANYAN_TERMINAL_CACHE_BENCH_LIMIT=str(args.cache_limit))
    with (root / "test.log").open("w") as log:
        child = subprocess.Popen(["swift", "test", "--skip-build", "--filter", "terminalViewCacheMemoryWorkload"],
                                 env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            for cycle in range(1, 4):
                phase = f"cycle-{cycle}"
                ready = root / f"{phase}.json"
                deadline = time.monotonic() + 180
                while not ready.exists():
                    if child.poll() is not None:
                        raise RuntimeError(f"fixture exited ({child.returncode}); see {root / 'test.log'}")
                    if time.monotonic() > deadline:
                        raise RuntimeError(f"timed out waiting for {phase}")
                    time.sleep(0.1)
                snapshot = json.loads(ready.read_text())
                for label, command in [("vmmap", ["/usr/bin/vmmap", "-summary"]),
                                       ("heap", ["/usr/bin/heap", "--noContent", "-s"])]:
                    with (root / f"{phase}.{label}.txt").open("w") as output:
                        subprocess.run(command + [str(snapshot["pid"])], stdout=output,
                                       stderr=subprocess.STDOUT, check=True, timeout=60)
                print(json.dumps(snapshot), flush=True)
                (root / f"{phase}.continue").touch()
            child.wait(timeout=60)
            if child.returncode:
                raise RuntimeError(f"fixture failed; see {root / 'test.log'}")
            cli = args.banyanctl
            if cli is None:
                binary_dir = subprocess.check_output(["swift", "build", "--show-bin-path"], text=True).strip()
                cli = Path(binary_dir) / "banyanctl"
            perf_env = dict(os.environ, BANYAN_FIXTURE_DATA_HOME=str(root / "data"))
            with (root / "perf.json").open("w") as output:
                subprocess.run([str(cli), "perf", "report", "--since", "1d", "--json"],
                               env=perf_env, stdout=output, check=True, timeout=30)
        finally:
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait(timeout=10)
            runtime_file = root / "runtime.json"
            if runtime_file.exists():
                runtime = json.loads(runtime_file.read_text())
                # Only the unique fixture socket is eligible for cleanup.
                if not runtime["socket"].startswith("terminal-cache-"):
                    raise RuntimeError("refusing to clean up a non-fixture tmux socket")
                subprocess.run([runtime["tmux"], "-L", runtime["socket"], "kill-server"],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=10)


if __name__ == "__main__":
    main()
