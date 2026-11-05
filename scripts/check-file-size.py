#!/usr/bin/env python3
"""Enforce the maintained-code line limit, including new untracked files."""

import argparse
from pathlib import Path
import subprocess
import sys


MAX_LINES = 1_000
REVIEW_LINES = 500
CODE_SUFFIXES = {
    ".swift", ".c", ".h", ".cc", ".cpp", ".hpp", ".m", ".mm",
    ".py", ".sh", ".bash", ".zsh", ".js", ".mjs", ".cjs", ".jsx",
    ".ts", ".tsx", ".rs", ".go", ".rb", ".sql", ".yml", ".yaml",
}
# This is upstream code. Packages/PuckSwift is maintained here and is checked.
VENDORED_ROOTS = ("Packages/SwiftTerm/",)


def source_files(root):
    output = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root,
    )
    for name in sorted(set(output.decode().split("\0")) - {""}):
        if name.startswith(VENDORED_ROOTS):
            continue
        path = root / name
        # Deleted tracked files and links to external files have no local source
        # to check. Git ignores build output, generated artifacts and dependencies.
        if path.is_symlink() or not path.is_file():
            continue
        if path.suffix.lower() in CODE_SUFFIXES:
            yield name, path
        elif not path.suffix:
            with path.open("rb") as source:
                if source.read(2) == b"#!":
                    yield name, path


def line_count(path):
    data = path.read_bytes()
    return data.count(b"\n") + int(bool(data) and not data.endswith(b"\n"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--warn", action="store_true",
        help="also list files above the 500-line review guideline",
    )
    args = parser.parse_args()
    try:
        root = Path(subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"], text=True,
        ).strip())
        checked = 0
        violations = []
        for name, path in source_files(root):
            checked += 1
            lines = line_count(path)
            if lines > MAX_LINES:
                violations.append((name, lines))
            elif args.warn and lines > REVIEW_LINES:
                print(f"Review: {name}: {lines} lines (guideline: {REVIEW_LINES})")
        for name, lines in violations:
            print(f"FAIL: {name}: {lines} lines (maximum: {MAX_LINES})")
        if violations:
            print("Split files by responsibility; comments and blank lines count.")
        print(f"Checked {checked} code files; {len(violations)} exceed {MAX_LINES} lines.")
        return 1 if violations else 0
    except (OSError, subprocess.CalledProcessError, UnicodeError) as error:
        print(f"Unable to check file sizes: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
