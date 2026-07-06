#!/usr/bin/env python3
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import sys
import urllib.request
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GITHUB_API_URL = (
    "https://api.github.com/repos/MetaCubeX/meta-rules-dat/releases/latest"
)
ASSET_NAME = "geoip.metadb"
CHECKSUM_ASSET_NAME = "geoip.metadb.sha256sum"
SOURCE_RECORD = ROOT / "docs" / "GEOIP_SOURCE.txt"
ASSET_PATHS = [
    ROOT / "SSRVPN_Android" / "assets" / "geoip.metadb.gz",
    ROOT / "SSRVPN_MacOS" / "assets" / "geoip.metadb.gz",
    ROOT / "SSRVPN_Windows" / "assets" / "geoip.metadb.gz",
]
HASH_RE = re.compile(r"\b([0-9a-fA-F]{64})\b")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def request(url: str) -> urllib.request.Request:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "SSRVPN-geoip-sync",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return urllib.request.Request(url, headers=headers)


def download(url: str) -> bytes:
    with urllib.request.urlopen(request(url), timeout=60) as response:
        return response.read()


def load_latest_release() -> dict[str, object]:
    return json.loads(download(GITHUB_API_URL).decode("utf-8"))


def find_asset(release: dict[str, object], name: str) -> dict[str, object]:
    for asset in release.get("assets", []):
        if isinstance(asset, dict) and asset.get("name") == name:
            return asset
    raise SystemExit(f"release does not contain {name}")


def parse_checksum(content: bytes) -> str:
    text = content.decode("utf-8", errors="replace")
    match = HASH_RE.search(text)
    if match is None:
        raise SystemExit(f"{CHECKSUM_ASSET_NAME} does not contain a SHA256")
    return match.group(1).lower()


def asset_digest(asset: dict[str, object]) -> str | None:
    digest = asset.get("digest")
    if not isinstance(digest, str):
        return None
    prefix = "sha256:"
    return digest.removeprefix(prefix).lower() if digest.startswith(prefix) else None


def build_source_record(
    release: dict[str, object],
    asset: dict[str, object],
    upstream_hash: str,
    gzip_hash: str,
) -> str:
    return "\n".join(
        [
            "Repo: MetaCubeX/meta-rules-dat",
            f"Release tag: {release.get('tag_name', '')}",
            f"Release name: {release.get('name', '')}",
            f"Asset URL: {asset.get('browser_download_url', '')}",
            f"Upstream SHA256: {upstream_hash}",
            f"Bundled gzip SHA256: {gzip_hash}",
            "",
        ],
    )


def sync(check: bool) -> int:
    release = load_latest_release()
    asset = find_asset(release, ASSET_NAME)
    checksum_asset = find_asset(release, CHECKSUM_ASSET_NAME)

    asset_url = str(asset["browser_download_url"])
    checksum_url = str(checksum_asset["browser_download_url"])
    expected_hash = parse_checksum(download(checksum_url))
    api_hash = asset_digest(asset)
    if api_hash is not None and api_hash != expected_hash:
        raise SystemExit(
            f"GitHub API digest {api_hash} does not match {CHECKSUM_ASSET_NAME} {expected_hash}",
        )

    raw = download(asset_url)
    actual_hash = sha256(raw)
    if actual_hash != expected_hash:
        raise SystemExit(
            f"{ASSET_NAME} SHA256 mismatch: expected {expected_hash}, got {actual_hash}",
        )

    gzipped = gzip.compress(raw, compresslevel=9, mtime=0)
    gzip_hash = sha256(gzipped)
    source_record = build_source_record(release, asset, actual_hash, gzip_hash)

    mismatches = [
        path
        for path in ASSET_PATHS
        if not path.exists() or path.read_bytes() != gzipped
    ]
    source_mismatch = (
        not SOURCE_RECORD.exists()
        or SOURCE_RECORD.read_text(encoding="utf-8") != source_record
    )
    if check:
        for path in mismatches:
            print(f"geoip sync: stale {path.relative_to(ROOT)}")
        if source_mismatch:
            print(f"geoip sync: stale {SOURCE_RECORD.relative_to(ROOT)}")
        return 1 if mismatches or source_mismatch else 0

    for path in ASSET_PATHS:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(gzipped)
        print(f"geoip sync: wrote {path.relative_to(ROOT)}")
    SOURCE_RECORD.write_text(source_record, encoding="utf-8")
    print(f"geoip sync: wrote {SOURCE_RECORD.relative_to(ROOT)}")
    print(f"geoip sync: upstream {actual_hash}")
    print(f"geoip sync: bundled gzip {gzip_hash}")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Download, verify, and bundle the latest geoip.metadb.",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Verify local assets match latest upstream without writing files.",
    )
    args = parser.parse_args()
    raise SystemExit(sync(check=args.check))


if __name__ == "__main__":
    main()
