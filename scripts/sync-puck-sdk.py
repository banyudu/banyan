#!/usr/bin/env python3
"""Vendor the public PuckSwift package with a reproducible content pin.

Usage: python3 scripts/sync-puck-sdk.py --source /path/to/puck/packages/PuckSwift
       python3 scripts/sync-puck-sdk.py --check
No build state or local paths are retained in the vendored package.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "Packages/PuckSwift"


def hashes(root):
    return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob("*")) if p.is_file()
            and p.name != "UPSTREAM.json"
            and not any(part.startswith(".") for part in p.relative_to(root).parts)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if args.check:
        expected = json.loads((TARGET / "UPSTREAM.json").read_text())["sha256"]
        if hashes(TARGET) != expected:
            raise SystemExit("Vendored PuckSwift differs from its pinned artifact; sync from the SDK source")
        print("PuckSwift artifact hashes verified")
        return
    if args.source is None:
        parser.error("provide --source or --check")
    source = args.source.resolve(strict=True)
    if not (source / "Package.swift").is_file() or not (source / "Sources/PuckSwift").is_dir():
        parser.error("source must be the public PuckSwift package")
    with tempfile.TemporaryDirectory(prefix="puck-sdk-sync-") as directory:
        staging = Path(directory) / "PuckSwift"
        staging.mkdir()
        for name in ["Package.swift", "Sources", "Tests", "README.md", "LICENSE"]:
            path = source / name
            if path.is_dir(): shutil.copytree(path, staging / name)
            elif path.is_file(): shutil.copy2(path, staging / name)
        artifact = {"upstream": "https://github.com/banyudu/puck", "source_directory": "packages/PuckSwift", "sha256": hashes(staging)}
        (staging / "UPSTREAM.json").write_text(json.dumps(artifact, indent=2) + "\n")
        TARGET.mkdir(parents=True, exist_ok=True)
        for path in TARGET.iterdir():
            if path.name.startswith("."): continue
            if path.is_dir(): shutil.rmtree(path)
            else: path.unlink()
        shutil.copytree(staging, TARGET, dirs_exist_ok=True)
    print("Vendored PuckSwift artifact; run --check to verify the pin")


if __name__ == "__main__":
    main()
