#!/usr/bin/env python3

import tempfile
import unittest
from pathlib import Path

from aur_release import pkgver_for_tag, update_pkgbuild


class AURReleaseTests(unittest.TestCase):
    def test_stable_release_tag(self):
        self.assertEqual(pkgver_for_tag("linux-v0.40.0"), "0.40.0")

    def test_linux_revision_tag_preserves_exact_tag_version(self):
        tag = "linux-v0.40.0+linux.2"
        pkgver = pkgver_for_tag(tag)
        self.assertEqual(pkgver, "0.40.0+linux.2")
        self.assertEqual(f"linux-v{pkgver}", tag)

    def test_prereleases_are_excluded(self):
        self.assertIsNone(pkgver_for_tag("linux-v0.40.0-rc.1"))
        self.assertIsNone(pkgver_for_tag("linux-v0.40.0-rc.1+linux.2"))

    def test_invalid_tags_are_rejected(self):
        for tag in ("linux-v0.40", "linux-v0.40.0+linux.0", "v0.40.0"):
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                pkgver_for_tag(tag)

    def test_pkgbuild_update_keeps_revision_in_pkgver_and_sources(self):
        contents = """pkgver=0.1.0
source=("${url}/releases/download/linux-v${pkgver}/agterm-linux-v${pkgver}-x86_64.tar.gz")
sha256sums=(
    '""" + "0" * 64 + "'\n    '" + "1" * 64 + "'\n)\n"
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "PKGBUILD"
            path.write_text(contents)
            update_pkgbuild(path, "linux-v0.40.0+linux.2", "a" * 64, "b" * 64)
            result = path.read_text()

        self.assertIn("pkgver=0.40.0+linux.2", result)
        self.assertIn("linux-v${pkgver}/agterm-linux-v${pkgver}", result)
        self.assertIn("'" + "a" * 64 + "'", result)
        self.assertIn("'" + "b" * 64 + "'", result)


if __name__ == "__main__":
    unittest.main()
