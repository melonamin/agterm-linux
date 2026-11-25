#!/usr/bin/env python3
"""Validate AUR release tags and prepare package metadata."""

import hashlib
import re
import sys
from pathlib import Path

_STABLE_TAG = re.compile(
    r"linux-v(?P<pkgver>[0-9]+\.[0-9]+\.[0-9]+(?:\+linux\.[1-9][0-9]*)?)"
)
_PRERELEASE_TAG = re.compile(
    r"linux-v[0-9]+\.[0-9]+\.[0-9]+-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*"
    r"(?:\+linux\.[1-9][0-9]*)?"
)


def pkgver_for_tag(tag: str) -> str | None:
    """Return Arch pkgver for stable tags; return None for prereleases."""
    if match := _STABLE_TAG.fullmatch(tag):
        return match.group("pkgver")
    if _PRERELEASE_TAG.fullmatch(tag):
        return None
    raise ValueError(f"unsupported Linux release tag: {tag}")


def update_pkgbuild(path: Path, tag: str, tarball_sha256: str, license_sha256: str) -> None:
    pkgver = pkgver_for_tag(tag)
    if pkgver is None:
        raise ValueError(f"prerelease is not published to AUR: {tag}")
    for checksum in (tarball_sha256, license_sha256):
        if not re.fullmatch(r"[0-9a-f]{64}", checksum):
            raise ValueError("invalid SHA-256 checksum")

    text = path.read_text()
    text, version_count = re.subn(r"(?m)^pkgver=.*$", f"pkgver={pkgver}", text)
    checksums = (
        "sha256sums=(\n"
        f"    '{tarball_sha256}'\n"
        f"    '{license_sha256}'\n"
        ")"
    )
    text, checksum_count = re.subn(
        r"(?ms)^sha256sums=\(\n\s*'[0-9a-f]{64}'\n\s*'[0-9a-f]{64}'\n\)",
        lambda _: checksums,
        text,
    )
    if version_count != 1 or checksum_count != 1:
        raise ValueError("could not update PKGBUILD version/checksums")
    path.write_text(text)


def update_from_manifest(path: Path, tag: str, manifest: Path, license_path: Path) -> None:
    pkgver = pkgver_for_tag(tag)
    if pkgver is None:
        raise ValueError(f"prerelease is not published to AUR: {tag}")
    asset = f"agterm-linux-v{pkgver}-x86_64.tar.gz"
    matches = []
    for line in manifest.read_text().splitlines():
        fields = line.split(maxsplit=1)
        if len(fields) == 2 and fields[1].removeprefix("*") == asset:
            matches.append(fields[0])
    if len(matches) != 1:
        raise ValueError(f"expected exactly one SHA-256 checksum for {asset}")
    license_sha256 = hashlib.sha256(license_path.read_bytes()).hexdigest()
    update_pkgbuild(path, tag, matches[0], license_sha256)


def main() -> None:
    command, *args = sys.argv[1:]
    if command == "validate-tag":
        tag, output_path = args
        pkgver = pkgver_for_tag(tag)
        with Path(output_path).open("a") as output:
            output.write(f"publish={'false' if pkgver is None else 'true'}\n")
            if pkgver is not None:
                output.write(f"pkgver={pkgver}\n")
        if pkgver is None:
            print(f"Skipping prerelease tag {tag}")
    elif command == "pkgver":
        pkgver = pkgver_for_tag(args[0])
        if pkgver is None:
            raise ValueError(f"no stable AUR package for prerelease: {args[0]}")
        print(pkgver)
    elif command == "update-pkgbuild":
        path, tag, tarball_sha256, license_sha256 = args
        update_pkgbuild(Path(path), tag, tarball_sha256, license_sha256)
    elif command == "update-from-manifest":
        path, tag, manifest, license_path = args
        update_from_manifest(Path(path), tag, Path(manifest), Path(license_path))
    else:
        raise ValueError(f"unknown command: {command}")


if __name__ == "__main__":
    try:
        main()
    except (IndexError, OSError, ValueError) as error:
        raise SystemExit(str(error)) from error
