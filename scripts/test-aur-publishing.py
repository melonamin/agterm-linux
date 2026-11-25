#!/usr/bin/env python3
"""Exercise release metadata validation and real git publication without contacting AUR."""

import hashlib
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
UPDATE = ROOT / "scripts/aur_release.py"
PUBLISH = ROOT / "scripts/publish-aur-package.sh"


class AURPublishingTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.package = self.root / "package"
        self.package.mkdir()
        self.template = (ROOT / "packaging/aur/PKGBUILD").read_text()
        (self.package / "PKGBUILD").write_text(self.template)
        self.manifest = self.root / "SHA256SUMS"

    def command(self, *args, success=True):
        result = subprocess.run(args, text=True, capture_output=True)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def metadata(self, version):
        self.manifest.write_text(f"{'a' * 64}  agterm-linux-v{version}-x86_64.tar.gz\n")
        self.command(sys.executable, str(UPDATE), "update-from-manifest", str(self.package / "PKGBUILD"),
                     "linux-v" + version, str(self.manifest), str(ROOT / "LICENSE"))
        self.command("bash", "-c", 'cd "$1" && makepkg --printsrcinfo > .SRCINFO', "_", str(self.package))

    def test_stable_and_revision_metadata(self):
        for version in ("0.40.0", "0.40.0+linux.2"):
            with self.subTest(version=version):
                self.metadata(version)
                text = (self.package / "PKGBUILD").read_text()
                self.assertIn(f"pkgver={version}\n", text)
                self.assertIn("'" + "a" * 64 + "'", text)
                self.assertIn(hashlib.sha256((ROOT / "LICENSE").read_bytes()).hexdigest(), text)
                self.assertIn(f"\tpkgver = {version}\n", (self.package / ".SRCINFO").read_text())

    def test_rejected_inputs_leave_metadata_unchanged(self):
        valid = f"{'a' * 64}  agterm-linux-v0.40.0-x86_64.tar.gz\n"
        cases = [
            ("linux-v0.40.0-rc.1", valid),
            ("linux-v0.40.0-rc.1+linux.1", valid),
            ("v0.40.0", valid),
            ("linux-v0.40.0+linux.0", valid),
            ("linux-v0.40.0", ""),
            ("linux-v0.40.0", valid + valid),
            ("linux-v0.40.0", valid.replace("a" * 64, "not-a-digest")),
            ("linux-v0.40.0", valid.replace("x86_64", "aarch64")),
            ("linux-v0.40.0", valid.replace("tar.gz", "tar.gz.extra")),
        ]
        for tag, contents in cases:
            with self.subTest(tag=tag, contents=contents):
                self.manifest.write_text(contents)
                self.command(sys.executable, str(UPDATE), "update-from-manifest", str(self.package / "PKGBUILD"),
                             tag, str(self.manifest), str(ROOT / "LICENSE"), success=False)
                self.assertEqual((self.package / "PKGBUILD").read_text(), self.template)

    def test_malformed_template_is_not_partially_updated(self):
        broken = self.template.replace("sha256sums=(", "missing_checksums=(")
        (self.package / "PKGBUILD").write_text(broken)
        self.manifest.write_text(f"{'a' * 64}  agterm-linux-v0.40.0-x86_64.tar.gz\n")
        self.command(sys.executable, str(UPDATE), "update-from-manifest", str(self.package / "PKGBUILD"),
                     "linux-v0.40.0", str(self.manifest), str(ROOT / "LICENSE"), success=False)
        self.assertEqual((self.package / "PKGBUILD").read_text(), broken)

    def test_publication_is_idempotent_and_never_downgrades(self):
        remote = self.root / "aur.git"
        self.command("git", "init", "--bare", "--initial-branch=master", str(remote))

        def publish(version):
            self.metadata(version)
            self.command(str(PUBLISH), str(self.package), str(remote), "linux-v" + version)
            return self.command("git", "--git-dir", str(remote), "rev-parse", "HEAD").stdout.strip()

        first = publish("0.40.0")
        self.assertEqual(publish("0.40.0"), first)
        revision = publish("0.40.0+linux.10")
        self.assertNotEqual(revision, first)
        for older in ("0.40.0", "0.40.0+linux.2", "0.39.1+linux.20"):
            self.assertEqual(publish(older), revision)
        newer = publish("0.41.0")
        self.assertNotEqual(newer, revision)
        contents = self.command("git", "--git-dir", str(remote), "show", "HEAD:.SRCINFO").stdout
        self.assertIn("\tpkgver = 0.41.0\n", contents)

    def test_rejected_publication_does_not_create_a_commit(self):
        remote = self.root / "aur.git"
        self.command("git", "init", "--bare", "--initial-branch=master", str(remote))
        self.metadata("0.40.0")
        for tag in ("linux-v0.41.0", "linux-v0.40.0-rc.1"):
            self.command(str(PUBLISH), str(self.package), str(remote), tag, success=False)
            self.command("git", "--git-dir", str(remote), "rev-parse", "--verify", "HEAD", success=False)


if __name__ == "__main__":
    unittest.main()
