#!/usr/bin/env python3
"""Build the public OSS update manifest from verified release artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


SHA256_RE = re.compile(r"\b[a-fA-F0-9]{64}\b")
VERSION_RE = re.compile(r"^\d+(?:\.\d+){1,3}$")


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_manifest(
    *, tag: str, base_url: str, changelog: str, assets: list[Path]
) -> dict[str, object]:
    version = tag.removeprefix("v")
    if not VERSION_RE.fullmatch(version):
        raise ValueError(f"invalid release tag: {tag}")
    if not base_url.startswith("https://"):
        raise ValueError("base URL must use HTTPS")

    manifest_assets: list[dict[str, str]] = []
    for asset in assets:
        if not asset.is_file():
            raise FileNotFoundError(asset)
        checksum_file = Path(f"{asset}.sha256")
        if not checksum_file.is_file():
            raise FileNotFoundError(checksum_file)
        match = SHA256_RE.search(checksum_file.read_text(encoding="utf-8"))
        if match is None:
            raise ValueError(f"invalid checksum file: {checksum_file}")
        expected = match.group(0).lower()
        actual = _sha256(asset)
        if actual != expected:
            raise ValueError(f"checksum mismatch: {asset}")
        manifest_assets.append(
            {
                "name": asset.name,
                "url": f"{base_url.rstrip('/')}/{asset.name}",
                "sha256": actual,
            }
        )

    return {
        "version": version,
        "changelog": changelog.strip(),
        "assets": manifest_assets,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--base-url", required=True)
    parser.add_argument("--release-notes", type=Path, required=True)
    parser.add_argument("--asset", action="append", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    manifest = build_manifest(
        tag=args.tag,
        base_url=args.base_url,
        changelog=args.release_notes.read_text(encoding="utf-8"),
        assets=args.asset,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
