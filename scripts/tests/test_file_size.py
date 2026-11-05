#!/usr/bin/env python3
"""Exercise the command against disposable repositories, without touching ours."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


CHECKER = Path(__file__).resolve().parents[1] / "check-file-size.py"


class FileSizeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True)

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def check(self, *args):
        return subprocess.run(
            [sys.executable, str(CHECKER), *args], cwd=self.root,
            capture_output=True, text=True,
        )

    def test_exact_limit_and_unterminated_last_line(self):
        for ending in (b"", b"\n", b"\r\n"):
            with self.subTest(ending=ending):
                self.write("Sources/example.swift", b"// comment\n" * 999 + b"last" + ending)
                result = self.check()
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.write("Sources/example.swift", b"\n" * 1000 + b"last" + ending)
                result = self.check()
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("1001 lines", result.stdout)

    def test_tracked_and_new_files_are_checked_once(self):
        self.write("Sources/with spaces.swift", b"\n" * 1001)
        subprocess.run(["git", "add", "Sources/with spaces.swift"], cwd=self.root, check=True)
        self.write("Tests/new.py", b"\n" * 1002)
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.count("FAIL:"), 2)
        self.assertIn("Checked 2 code files", result.stdout)

    def test_exclusions_and_owned_package(self):
        self.write(".gitignore", b".build/\nnode_modules/\n")
        for name in ("README.md", "docs/design.md", "Package.resolved", "package-lock.json",
                     "Packages/SwiftTerm/Terminal.swift", ".build/generated.swift",
                     "node_modules/library/index.js"):
            self.write(name, b"\n" * 2001)
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stdout)
        self.write("Packages/PuckSwift/Sources/PuckSwift/Client.swift", b"\n" * 1001)
        result = self.check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("Packages/PuckSwift/", result.stdout)

    def test_deleted_files_links_and_extensionless_scripts(self):
        path = self.write("deleted.swift", b"\n" * 1001)
        subprocess.run(["git", "add", "deleted.swift"], cwd=self.root, check=True)
        path.unlink()
        (self.root / "link.swift").symlink_to("deleted.swift")
        self.write("scripts/check", b"#!/bin/sh\n" + b"\n" * 1000)
        result = self.check()
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Checked 1 code files", result.stdout)
        self.assertIn("scripts/check", result.stdout)

    def test_soft_guideline_is_optional_and_nonblocking(self):
        self.write("Sources/small.swift", b"\n" * 500)
        self.write("Sources/larger.swift", "// 中文\r\n".encode() * 501)
        self.assertNotIn("Review:", self.check().stdout)
        result = self.check("--warn")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.count("Review:"), 1)
        self.assertIn("501 lines", result.stdout)


if __name__ == "__main__":
    unittest.main()
