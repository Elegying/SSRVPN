#!/usr/bin/env python3
"""Validate metadata before allowing a release retry from an older main tip."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


REQUIRED_ASSETS = {
    "SSRVPN.apk",
    "SSRVPN.apk.sha256",
    "SSRVPN.dmg",
    "SSRVPN.dmg.sha256",
    "SSRVPN_Setup.exe",
    "SSRVPN_Setup.exe.sha256",
    "SSRVPN-release-provenance.json",
}
SHA256_DIGEST = re.compile(r"sha256:[0-9a-f]{64}")


CANONICAL_BINARIES = {
    "SSRVPN.apk",
    "SSRVPN.dmg",
    "SSRVPN_Setup.exe",
}


def validate_downloaded_asset_digest(
    release: object,
    asset_name: str,
    payload: bytes,
) -> None:
    if not isinstance(release, dict) or not isinstance(release.get("assets"), list):
        raise ValueError("GitHub release has no asset list")
    matches = [
        item
        for item in release["assets"]
        if isinstance(item, dict) and item.get("name") == asset_name
    ]
    if len(matches) != 1:
        raise ValueError(f"GitHub release asset is missing or duplicated: {asset_name}")
    expected = str(matches[0].get("digest") or "")
    actual = "sha256:" + hashlib.sha256(payload).hexdigest()
    if expected != actual:
        raise ValueError(f"downloaded asset digest mismatch: {asset_name}")


def validate_release_metadata(
    release: object,
    provenance: object,
    *,
    expected_tag: str,
    expected_commit: str,
) -> None:
    if not isinstance(release, dict):
        raise ValueError("GitHub release response is not an object")
    if not isinstance(release.get("draft"), bool):
        raise ValueError("GitHub release draft state is invalid")
    if not isinstance(release.get("prerelease"), bool):
        raise ValueError("GitHub release prerelease state is invalid")
    if release["prerelease"] is True:
        raise ValueError("prerelease cannot be retried into the stable channel")
    raw_assets = release.get("assets")
    if not isinstance(raw_assets, list):
        raise ValueError("GitHub release has no asset list")
    assets = {
        item.get("name"): item
        for item in raw_assets
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    }
    if len(assets) != len(raw_assets):
        raise ValueError("GitHub release has invalid or duplicated assets")
    missing = sorted(REQUIRED_ASSETS - set(assets))
    if missing:
        raise ValueError("GitHub release is incomplete: " + ", ".join(missing))
    unexpected = sorted(set(assets) - REQUIRED_ASSETS)
    if unexpected:
        raise ValueError(
            "GitHub release has unexpected assets: " + ", ".join(unexpected)
        )
    for name in sorted(REQUIRED_ASSETS):
        asset = assets[name]
        size = int(asset.get("size") or 0)
        limit = (
            64 * 1024
            if name.endswith(".sha256") or name.endswith(".json")
            else 300 * 1024 * 1024
        )
        if size <= 0 or size > limit:
            raise ValueError(f"GitHub release asset has invalid size: {name}")
        digest = str(asset.get("digest") or "")
        if SHA256_DIGEST.fullmatch(digest) is None:
            raise ValueError(f"GitHub release asset has no trusted digest: {name}")
    if not isinstance(provenance, dict) or provenance.get("schema") != 1:
        raise ValueError("release provenance is invalid")
    if provenance.get("tag") != expected_tag:
        raise ValueError("release provenance tag does not match the retry tag")
    if provenance.get("commit") != expected_commit:
        raise ValueError("release provenance commit does not match the tag commit")
    provenance_assets = provenance.get("assets")
    if not isinstance(provenance_assets, dict):
        raise ValueError("release provenance has no asset digest map")
    for name in CANONICAL_BINARIES:
        expected_digest = str(assets[name].get("digest") or "").removeprefix(
            "sha256:"
        )
        if provenance_assets.get(name) != expected_digest:
            raise ValueError(f"release provenance digest mismatch: {name}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("release_json", type=Path)
    parser.add_argument("provenance_json", type=Path)
    parser.add_argument("--expected-tag", required=True)
    parser.add_argument("--expected-commit", required=True)
    args = parser.parse_args()
    release_payload = args.release_json.read_bytes()
    provenance_payload = args.provenance_json.read_bytes()
    release_data = json.loads(release_payload)
    provenance_data = json.loads(provenance_payload)
    validate_downloaded_asset_digest(
        release_data,
        "SSRVPN-release-provenance.json",
        provenance_payload,
    )
    validate_release_metadata(
        release_data,
        provenance_data,
        expected_tag=args.expected_tag,
        expected_commit=args.expected_commit,
    )


if __name__ == "__main__":
    main()
