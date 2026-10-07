#!/usr/bin/env python3
"""Verify package contents using fake build/signing commands and private paths."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


FAKE_COMMAND = """#!/usr/bin/env python3
import os
from pathlib import Path
import sys

command = Path(sys.argv[0]).name
if command == "swift":
    if "--show-bin-path" in sys.argv:
        print(os.environ["PACKAGE_TEST_PRODUCTS"])
elif command == "pgrep":
    sys.exit(1)
elif command not in ("codesign", "security"):
    raise SystemExit("Unexpected command: " + command)
"""


class PackageAppTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="banyan package test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        source = Path(__file__).resolve().parents[1]
        (self.root / "scripts/lib").mkdir(parents=True)
        shutil.copy2(source / "package-app.sh", self.root / "scripts/package-app.sh")
        shutil.copy2(source / "lib/repo-root.sh", self.root / "scripts/lib/repo-root.sh")
        (self.root / "Assets").mkdir()
        (self.root / "Assets/AppIcon.icns").write_bytes(b"icon")
        self.bin = self.root / "fake-bin"
        self.bin.mkdir()
        for name in ("swift", "codesign", "security", "pgrep"):
            path = self.bin / name
            path.write_text(FAKE_COMMAND)
            path.chmod(0o755)
        self.install = self.root / "installed"
        self.install.mkdir()

    def products(self, layout):
        products = self.root / layout
        products.mkdir(parents=True)
        for name in ("Banyan", "banyanctl"):
            (products / name).write_bytes(name.encode())
        for name in ("Banyan_Banyan.bundle", "SwiftTerm_SwiftTerm.bundle"):
            bundle = products / name
            bundle.mkdir()
            (bundle / "resource.txt").write_text(name)
        return products

    def package(self, products):
        env = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                   PACKAGE_TEST_PRODUCTS=str(products), BANYAN_INSTALL_DIR=str(self.install),
                   BANYAN_SIGNING_IDENTITY="test-identity", BANYAN_SKIP_INSTALL="0")
        return subprocess.run(["bash", str(self.root / "scripts/package-app.sh"), "--here"],
                              env=env, capture_output=True, text=True, timeout=30)

    def assert_bundles_packaged(self, layout):
        result = self.package(self.products(layout))
        self.assertEqual(result.returncode, 0, result.stderr)
        for app in (self.root / "dist/Banyan.app", self.install / "Banyan.app"):
            for name in ("Banyan_Banyan.bundle", "SwiftTerm_SwiftTerm.bundle"):
                self.assertEqual((app / "Contents/Resources" / name / "resource.txt").read_text(), name)

    def test_capitalized_release_layout_includes_required_bundles(self):
        self.assert_bundles_packaged(".build/out/Products/Release")

    def test_architecture_release_layout_includes_required_bundles(self):
        self.assert_bundles_packaged(".build/arm64-apple-macosx/release")

    def test_missing_bundle_fails_without_replacing_installed_app(self):
        products = self.products(".build/out/Products/Release")
        shutil.rmtree(products / "Banyan_Banyan.bundle")
        installed = self.install / "Banyan.app"
        installed.mkdir()
        marker = installed / "previous-build"
        marker.write_text("keep")
        result = self.package(products)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required resource bundle missing", result.stderr)
        self.assertEqual(marker.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
