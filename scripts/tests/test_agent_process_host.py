#!/usr/bin/env python3
"""Exercise only synthetic commands, temporary homes and UUID tmux sockets."""

import os
from pathlib import Path
import pty
import shutil
import signal
import subprocess
import tempfile
import termios
import time
import unittest
import uuid
import fcntl
import struct


HOST = os.environ.get("BANYAN_PROCESS_HOST")
if not HOST:
    HOST = str(Path(__file__).resolve().parents[2] / ".build/debug/banyanctl")
HOST = str(Path(HOST).resolve())


def wait_for(predicate, seconds=5):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError("timed out waiting for synthetic process state")


def alive(pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True)
    return result.returncode == 0 and not result.stdout.strip().startswith("Z")


class ProcessHostTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="banyan-host-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, HOME=str(self.root), SHELL="/bin/sh", TERM="xterm-256color")
        self.script = self.root / "synthetic.py"
        self.script.write_text(SYNTHETIC)
        self.command = "exec /usr/bin/python3 " + str(self.script) + " " + str(self.root)
        self.processes = []
        self.addCleanup(self.cleanup)
        self.socket = "banyan-host-test-" + uuid.uuid4().hex
        self.tmux_path = shutil.which("tmux")
        self.clients = []
        self.fds = []

    def cleanup(self):
        for process in self.clients:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
        if self.tmux_path:
            self.tmux("kill-server", check=False)
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            for pipe in (process.stdin, process.stdout, process.stderr):
                if pipe:
                    pipe.close()
        # Only kill a remaining fixture process if its command still names our
        # unique script. This never signals an unrelated or reused PID.
        for name in ("pid", "grandchild", "separate"):
            path = self.root / name
            if path.exists():
                pid = int(path.read_text())
                command = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True).stdout
                if str(self.script) in command:
                    os.kill(pid, signal.SIGKILL)
        for fd in self.fds:
            os.close(fd)

    def host(self, command=None):
        process = subprocess.Popen([HOST, "__process-host", "/bin/sh", command or self.command],
                                   env=self.env, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.processes.append(process)
        return process

    def tmux(self, *arguments, check=True):
        return subprocess.run([self.tmux_path, "-L", self.socket, "-f", "/dev/null", *arguments],
                              env=self.env, capture_output=True, text=True, check=check, timeout=5).stdout.strip()

    def test_normal_and_signal_exit_status(self):
        for command, status in [("exit 0", 0), ("exit 7", 7), ("kill -TERM $$", 143), ("kill -HUP $$", 129)]:
            process = self.host(command)
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, status)

    def test_hup_term_forward_to_child_group_and_reap(self):
        for number in (signal.SIGHUP, signal.SIGTERM):
            for name in ("ready", "pid", "grandchild", "signal", "grandchild-signal"):
                (self.root / name).unlink(missing_ok=True)
            process = self.host()
            wait_for(lambda: (self.root / "ready").exists())
            pid = int((self.root / "pid").read_text())
            grandchild = int((self.root / "grandchild").read_text())
            self.assertEqual(os.getpgid(pid), pid)
            self.assertEqual(os.getpgid(grandchild), pid)
            if number == signal.SIGTERM:
                os.killpg(pid, signal.SIGSTOP)
                wait_for(lambda: subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True).stdout.strip().startswith("T"))
            os.kill(process.pid, number)
            # Keep stdin open until the signal is handled; communicate() would
            # otherwise race HUP against a normal EOF exit from the input loop.
            process.wait(timeout=5)
            process.communicate(timeout=5)
            self.assertEqual(process.returncode, 128 + number)
            wait_for(lambda: (self.root / "grandchild-signal").exists())
            self.assertEqual(int((self.root / "signal").read_text()), number)
            self.assertEqual(int((self.root / "grandchild-signal").read_text()), number)
            wait_for(lambda: not alive(pid) and not alive(grandchild))

    def test_forwarding_signals_during_spawn_do_not_orphan_a_child(self):
        # Includes before main(), during Swift setup, and after posix_spawn.
        for delay in (0, .001, .002, .004, .008, .016, .032, .064):
            (self.root / "pid").unlink(missing_ok=True)
            process = self.host(self.command + " race")
            time.sleep(delay)
            if process.poll() is None:
                os.kill(process.pid, signal.SIGTERM)
            process.communicate(timeout=5)
            time.sleep(.1)
            path = self.root / "pid"
            if path.exists():
                pid = int(path.read_text())
                wait_for(lambda: not alive(pid))

    def attach(self):
        master, slave = pty.openpty()
        self.fds.append(master)
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        def terminal():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        process = subprocess.Popen([self.tmux_path, "-L", self.socket, "attach-session", "-t", "synthetic"],
                                   env=self.env, stdin=slave, stdout=slave, stderr=slave, preexec_fn=terminal)
        os.close(slave)
        self.clients.append(process)
        wait_for(lambda: self.tmux("display-message", "-p", "-t", "synthetic", "#{session_attached}") == "1")
        return process, master

    def test_private_tmux_input_foreground_ctrl_c_stop_and_attach_continuity(self):
        self.assertIsNotNone(self.tmux_path)
        self.tmux("new-session", "-d", "-s", "synthetic", HOST, "__process-host", "/bin/sh", self.command)
        wait_for(lambda: (self.root / "ready").exists())
        pid = int((self.root / "pid").read_text())
        pane_root = int(self.tmux("display-message", "-p", "-t", "synthetic", "#{pane_pid}"))
        self.assertNotEqual(pid, pane_root)
        self.assertEqual((self.root / "foreground").read_text(), "True")
        client, fd = self.attach()
        os.write(fd, b"hello\n")
        wait_for(lambda: (self.root / "input").exists())
        self.assertEqual((self.root / "input").read_text(), "hello")
        os.write(fd, b"\x03")
        wait_for(lambda: (self.root / "interrupt").exists())
        self.assertTrue(alive(pid))
        os.write(fd, b"\x1a")
        wait_for(lambda: subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True).stdout.strip().startswith("T"))
        time.sleep(.2)
        self.assertTrue(subprocess.run(["ps", "-p", str(pid), "-o", "stat="], capture_output=True, text=True).stdout.strip().startswith("T"))
        # Explicit synthetic recovery here; Swift store tests exercise the
        # identity-checked session unfreeze path without a journal.
        os.killpg(pid, signal.SIGCONT)
        os.write(fd, b"\x02d")
        client.wait(timeout=5)
        self.assertTrue(alive(pid))
        _, next_fd = self.attach()
        os.write(next_fd, b"again\n")
        wait_for(lambda: (self.root / "input").read_text() == "again")
        self.assertEqual(int((self.root / "pid").read_text()), pid)
        grandchild = int((self.root / "grandchild").read_text())
        self.tmux("kill-session", "-t", "synthetic")
        wait_for(lambda: not alive(pid) and not alive(grandchild))

    def test_normal_command_exit_preserves_deliberate_background_child(self):
        self.tmux("new-session", "-d", "-s", "synthetic", HOST, "__process-host", "/bin/sh", self.command + " background")
        self.tmux("set-option", "-t", "synthetic", "remain-on-exit", "on")
        wait_for(lambda: (self.root / "ready").exists())
        background = int((self.root / "separate").read_text())
        self.tmux("send-keys", "-t", "synthetic", "exit", "Enter")
        wait_for(lambda: self.tmux("display-message", "-p", "-t", "synthetic", "#{pane_dead}") == "1")
        self.assertEqual(self.tmux("display-message", "-p", "-t", "synthetic", "#{pane_dead_status}"), "7")
        time.sleep(.2)
        self.assertTrue(alive(background), "ordinary command exit killed a deliberate background server")
        self.tmux("kill-session", "-t", "synthetic")
        self.assertTrue(alive(background), "terminal teardown killed a nohup background server")
        # cleanup() verifies the unique fixture command before killing this PID.


SYNTHETIC = r'''
import os, pathlib, signal, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
grandchild = len(sys.argv) > 2 and sys.argv[2] in ('grandchild', 'separate')
race = len(sys.argv) > 2 and sys.argv[2] == 'race'
background = len(sys.argv) > 2 and sys.argv[2] == 'background'
def finish(number, frame):
    (root / ('grandchild-signal' if grandchild else 'signal')).write_text(str(number))
    sys.exit(128 + number)
signal.signal(signal.SIGHUP, finish)
signal.signal(signal.SIGTERM, finish)
if grandchild:
    if sys.argv[2] == 'separate': signal.signal(signal.SIGHUP, signal.SIG_IGN)
    (root / sys.argv[2]).write_text(str(os.getpid()))
    while True: time.sleep(1)
(root / 'pid').write_text(str(os.getpid()))
if race:
    while True: time.sleep(1)
if background:
    subprocess.Popen([sys.executable, __file__, str(root), 'separate'], preexec_fn=os.setpgrp,
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    while not (root / 'separate').exists(): time.sleep(.01)
else:
    child = subprocess.Popen([sys.executable, __file__, str(root), 'grandchild'])
    while not (root / 'grandchild').exists(): time.sleep(.01)
if os.isatty(0):
    (root / 'foreground').write_text(str(os.tcgetpgrp(0) == os.getpgrp()))
def interrupt(number, frame):
    (root / 'interrupt').touch()
signal.signal(signal.SIGINT, interrupt)
print('synthetic ready', flush=True)
(root / 'ready').touch()
for line in sys.stdin:
    if line.strip() == 'exit': sys.exit(7)
    (root / 'input').write_text(line.strip())
'''


if __name__ == "__main__":
    unittest.main()
