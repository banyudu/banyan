#!/usr/bin/env python3
"""Exercise restart recovery with fake OS commands; never touch a running app."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


FAKE_COMMAND = """#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["RESTART_TEST_ROOT"])
state_path = root / "calls.json"
state = json.loads(state_path.read_text()) if state_path.exists() else []
command = Path(sys.argv[0]).name
state.append([command, *sys.argv[1:]])
state_path.write_text(json.dumps(state))
opens = sum(call[0] == "open" for call in state)
mode = os.environ["RESTART_TEST_MODE"]
if command == "open":
    sys.exit(0)
if command == "pgrep":
    sys.exit(0 if opens and mode != "exited" else 1)
if command == "lsof":
    sys.exit(1)
if command == "sleep":
    sys.exit(0)
if command == "banyanctl":
    sys.exit(0 if mode == "healthy" or (mode == "reopen" and opens == 2) else 1)
raise SystemExit("Unexpected OS command: " + command)
"""


class RestartAppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="banyan restart test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        source = Path(__file__).resolve().parents[1]
        (self.root / "scripts/lib").mkdir(parents=True)
        shutil.copy2(source / "restart-app.sh", self.root / "scripts/restart-app.sh")
        shutil.copy2(source / "lib/repo-root.sh", self.root / "scripts/lib/repo-root.sh")
        self.bin = self.root / "fake-bin"
        self.bin.mkdir()
        for name in ("open", "pgrep", "lsof", "sleep", "pkill", "osascript", "ps"):
            self.executable(self.bin / name, FAKE_COMMAND)
        self.app = self.root / "dist/Banyan.app"
        self.executable(self.app / "Contents/MacOS/Banyan", "#!/bin/sh\nexit 99\n")
        self.ctl = self.root / "dist/bin/banyanctl"
        self.executable(self.ctl, FAKE_COMMAND)

    def executable(self, path, content):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
        path.chmod(0o755)

    def run_restart(self, mode):
        env = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                   RESTART_TEST_ROOT=str(self.root), RESTART_TEST_MODE=mode)
        result = subprocess.run(
            ["bash", str(self.root / "scripts/restart-app.sh"), "--here"],
            env=env, capture_output=True, text=True, timeout=30,
        )
        self.calls = json.loads((self.root / "calls.json").read_text())
        self.assertFalse(any(call[0] in ("pkill", "osascript", "ps") for call in self.calls))
        return result

    def assert_calls(self, opens, probes):
        # Opening precisely the same bundle without -n reuses the instance.
        self.assertEqual([call for call in self.calls if call[0] == "open"],
                         [["open", str(self.app)]] * opens)
        self.assertEqual(sum(call[0] == "banyanctl" for call in self.calls), probes)

    def test_healthy_launch_does_not_reopen(self):
        result = self.run_restart("healthy")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_calls(opens=1, probes=1)

    def test_running_unresponsive_app_recovers_by_reopening(self):
        result = self.run_restart("reopen")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("possible windowless launch", result.stderr)
        self.assert_calls(opens=2, probes=26)

    def test_failed_recovery_is_bounded_and_returns_failure(self):
        result = self.run_restart("unresponsive")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("two 25s health checks", result.stderr)
        self.assert_calls(opens=2, probes=50)

    def test_exited_app_is_not_relaunched_in_a_loop(self):
        result = self.run_restart("exited")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("process is not running", result.stderr)
        self.assert_calls(opens=1, probes=25)

    def test_missing_cli_keeps_existing_launch_behavior(self):
        self.ctl.unlink()
        result = self.run_restart("unresponsive")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_calls(opens=1, probes=0)


if __name__ == "__main__":
    unittest.main()
