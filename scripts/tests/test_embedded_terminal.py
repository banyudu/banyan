#!/usr/bin/env python3
"""Exercise the real embedded TUI on a private tmux server and private data home.

Build first: swift build --product BanyanTUI
Run: python3 scripts/tests/test_embedded_terminal.py
No live app, control server, database, agent, or tmux socket is used.
"""

import argparse
import codecs
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time
import uuid


class Screen:
    """Decode the host renderer's CUP/SGR/erase stream for spatial assertions."""

    def __init__(self, rows=30, columns=100):
        self.rows, self.columns = rows, columns
        self.cells = [[" "] * columns for _ in range(rows)]
        self.row = self.column = 0
        self.sequence = ""
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.raw = ""

    def feed(self, data):
        text = self.decoder.decode(data)
        self.raw += text
        for char in text:
            if self.sequence:
                self.sequence += char
                if self.sequence == "\x1b[":
                    continue
                if len(self.sequence) > 2 and "@" <= char <= "~":
                    values = self.sequence[2:-1]
                    if char == "H":
                        parts = [int(x or "1") for x in values.split(";")]
                        self.row = (parts[0] if parts else 1) - 1
                        self.column = (parts[1] if len(parts) > 1 else 1) - 1
                    elif char == "J" and values == "2":
                        self.cells = [[" "] * self.columns for _ in range(self.rows)]
                    self.sequence = ""
            elif char == "\x1b":
                self.sequence = char
            elif char >= " ":
                if 0 <= self.row < self.rows and 0 <= self.column < self.columns:
                    self.cells[self.row][self.column] = char
                self.column = min(self.columns - 1, self.column + 1)

    def text(self):
        return "\n".join("".join(row) for row in self.cells)

    def terminal_line(self, value):
        start = 0 if self.columns < 40 else min(34, self.columns // 3) + 1
        return any("".join(row[start:]).strip() == value for row in self.cells[3:-1])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path)
    args = parser.parse_args()
    binary = args.binary
    if binary is None:
        directory = subprocess.check_output(["swift", "build", "--show-bin-path"], text=True).strip()
        binary = Path(directory) / "BanyanTUI"
    binary = binary.resolve()
    tmux = shutil.which("tmux")
    assert tmux, "tmux is required"
    socket = "banyan-tui-fixture-" + uuid.uuid4().hex
    # Keep the Unix socket path below macOS's sockaddr_un limit, even after
    # tmux adds its uid directory and the unique fixture socket name.
    with tempfile.TemporaryDirectory(prefix="bt-", dir="/tmp") as temporary:
        root = Path(temporary)
        env = dict(os.environ, HOME=str(root), ZDOTDIR=str(root), SHELL="/bin/sh",
                   HISTFILE="/dev/null", ENV="/dev/null", BASH_ENV="/dev/null",
                   TERM="xterm-256color", TMUX_TMPDIR=str(root),
                   BANYAN_FIXTURE_DATA_HOME=str(root), BANYAN_FIXTURE_TMUX_SOCKET=socket)
        for key in ["TMUX", "TMUX_PANE", "CLICOLOR_FORCE", "FORCE_COLOR", "GH_FORCE_TTY"]:
            env.pop(key, None)
        client = None
        master = None

        def command(*arguments, check=True):
            return subprocess.run([tmux, "-L", socket, *arguments], env=env, check=check,
                                  capture_output=True, text=True, timeout=10).stdout.strip()

        def start():
            nonlocal client, master, screen
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))

            def terminal_session():
                os.setsid()
                fcntl.ioctl(0, termios.TIOCSCTTY, 0)

            client = subprocess.Popen([str(binary)], stdin=slave, stdout=slave, stderr=slave,
                                      env=env, cwd=root, preexec_fn=terminal_session)
            os.close(slave)
            screen = Screen()
            wait(lambda: "Banyan TUI" in screen.text(), "TUI startup")

        def send(value):
            os.write(master, value.encode() if isinstance(value, str) else value)

        def wait(condition, label, timeout=12):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                if condition():
                    return
                assert client.poll() is None, f"TUI exited during {label}: {screen.raw[-2000:]}"
                readable, _, _ = select.select([master], [], [], 0.1)
                if readable:
                    screen.feed(os.read(master, 65536))
            diagnostics = {"tty": termios.tcgetattr(master)}
            # Read only our owned fixture child when diagnosing Linux failures.
            for name in ["wchan", "status"]:
                path = Path(f"/proc/{client.pid}/{name}")
                if path.exists():
                    diagnostics[name] = path.read_text()
            raise AssertionError(f"Timed out: {label}\n{screen.text()}\n{screen.raw[-1000:]!r}\n{diagnostics}")

        def stop():
            nonlocal client, master
            if client and client.poll() is None:
                client.send_signal(signal.SIGTERM)
                try:
                    client.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    client.kill()  # only the owned fixture TUI, never a process group
                    client.wait(timeout=10)
            if master is not None:
                os.close(master)
            client = master = None

        try:
            start()
            send("n")
            wait(lambda: "Created" in screen.text(), "create first private shell")
            names = command("list-sessions", "-F", "#{session_name}").splitlines()
            assert len(names) == 1
            first = names[0]
            # Enter and command in one read must not drop the command bytes.
            send("\rprintf '\\033[31mEMBEDDED_ONE\\033[0m\\n'\r")
            wait(lambda: screen.terminal_line("EMBEDDED_ONE"), "interactive input and ANSI output")
            assert any("EMBEDDED_ONE" in "".join(row[34:]) for row in screen.cells[3:-1])
            assert any("Shell" in "".join(row[:33]) for row in screen.cells[3:-1])
            assert re.search(r"\x1b\[[0-9;]*38;5;1m", screen.raw), "ANSI color was lost"
            # Output must redraw with no stdin activity.
            send("sleep 0.2; printf 'ASYNC_OUTPUT\\n'\r")
            wait(lambda: screen.terminal_line("ASYNC_OUTPUT"), "event-driven output")

            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 36, 120, 0, 0))
            os.kill(client.pid, signal.SIGWINCH)
            screen = Screen(rows=36, columns=120)
            send("stty size\r")
            wait(lambda: screen.terminal_line("32 85"), "resize reaches backing pane")

            # Tmux owns history, including before attachment and across restart.
            send("printf 'HISTORY_SENTINEL\\n'; seq 1 80\r")
            wait(lambda: screen.terminal_line("80"), "scrolling output")
            assert "HISTORY_SENTINEL" in command("capture-pane", "-p", "-S", "-", "-t", first)
            send(b"\x02[")
            wait(lambda: bool(command("display-message", "-p", "-t", first, "#{pane_in_mode}")) and
                 command("display-message", "-p", "-t", first, "#{pane_in_mode}") == "1", "copy mode")
            send("q")

            send("printf '\\033[?1049h\\033[2J\\033[HALTERNATE_SENTINEL'; read answer; printf '\\033[?1049l'\r")
            wait(lambda: screen.terminal_line("ALTERNATE_SENTINEL"), "alternate screen")
            send("done\r")
            wait(lambda: not screen.terminal_line("ALTERNATE_SENTINEL"), "alternate screen restoration")

            send(b"\x1d]n")
            wait(lambda: len(command("list-sessions", "-F", "#{session_name}").splitlines()) == 2, "second private shell")
            send("j\rprintf 'EMBEDDED_TWO\\n'\r")
            wait(lambda: screen.terminal_line("EMBEDDED_TWO"), "second session input")
            send(b"\x1dk")
            wait(lambda: "EMBEDDED_TWO" not in screen.text(), "switch back")
            assert command("has-session", "-t", first) == ""
            assert "HISTORY_SENTINEL" in command("capture-pane", "-p", "-S", "-", "-t", first)

            # Kill ONLY this fixture's tmux client, leaving its server and shells.
            command("detach-client", "-s", first)
            wait(lambda: "disconnected" in screen.text(), "client exit notification")
            wait(lambda: "disconnected" not in screen.text(), "automatic reconnect", timeout=15)

            send(b"\x1d]f")
            wait(lambda: "Banyan TUI" not in screen.text(), "full-screen fallback")
            # Detach the foreground fallback through tmux's own prefix.
            send(b"\x02d")
            wait(lambda: "Banyan TUI" in screen.text(), "fallback returns to embedded screen")
            send("\x1b")
            expired = time.monotonic() + 0.25
            wait(lambda: time.monotonic() >= expired, "sidebar Escape deadline")
            send("j\rprintf 'AFTER_ESCAPE\\n'\r")
            wait(lambda: screen.terminal_line("AFTER_ESCAPE"), "navigation after lone Escape")
            stop()
            assert len(command("list-sessions", "-F", "#{session_name}").splitlines()) == 2
            start()
            send("\rprintf 'AFTER_RESTART\\n'\r")
            wait(lambda: screen.terminal_line("AFTER_RESTART"), "restart reconnect")
            send(b"\x1d]q")
            client.wait(timeout=10)
            assert client.returncode == 0
            print("PASS: embedded input, color, live output, resize, scrollback, alternate screen, switch, detach/reconnect, restart")
        finally:
            stop()
            assert socket.startswith("banyan-tui-fixture-")
            command("kill-server", check=False)


if __name__ == "__main__":
    main()
