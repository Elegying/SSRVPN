#!/usr/bin/env python3
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import re
import sys
import time
import urllib.request
from pathlib import Path
from urllib.parse import quote, urlsplit


ROOT = Path(__file__).resolve().parents[1]
UPSTREAM_REPO = "MetaCubeX/meta-rules-dat"
GITHUB_API_BASE = f"https://api.github.com/repos/{UPSTREAM_REPO}"
GITHUB_API_URL = f"{GITHUB_API_BASE}/releases/latest"
SOURCE_ARCHIVE_PREFIX = f"https://github.com/{UPSTREAM_REPO}/archive/"
ASSET_NAME = "geoip.metadb"
CHECKSUM_ASSET_NAME = "geoip.metadb.sha256sum"
MIRROR_REPO = "Elegying/SSRVPN"
MIRROR_RELEASE_TAG = "core-assets-v1"
MIRROR_URL_PREFIX = (
    "https://github.com/Elegying/SSRVPN/releases/download/core-assets-v1/"
)
SOURCE_RECORD = ROOT / "docs" / "GEOIP_SOURCE.txt"
ASSET_PATHS = [
    ROOT / "SSRVPN_Android" / "assets" / "geoip.metadb.gz",
    ROOT / "SSRVPN_MacOS" / "assets" / "geoip.metadb.gz",
    ROOT / "SSRVPN_Windows" / "assets" / "geoip.metadb.gz",
]
HASH_RE = re.compile(r"\b([0-9a-fA-F]{64})\b")
FULL_GIT_SHA_RE = re.compile(r"^[0-9a-fA-F]{40}$")
MAX_RELEASE_METADATA_BYTES = 2 * 1024 * 1024
MAX_CHECKSUM_BYTES = 64 * 1024
MAX_GEOIP_BYTES = 64 * 1024 * 1024
MAX_DOWNLOAD_SECONDS = 60
DOWNLOAD_CHUNK_BYTES = 64 * 1024
MAX_TAG_PEEL_DEPTH = 4


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        req,
        fp,
        code,
        msg,
        headers,
        newurl,
    ):
        # Authenticated GitHub API calls never need redirects. Refusing every
        # redirect keeps urllib from copying Authorization to another origin.
        return None


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def stable_gzip(data: bytes) -> bytes:
    gzipped = gzip.compress(data, compresslevel=9, mtime=0)
    if len(gzipped) < 10:
        raise SystemExit("gzip output is unexpectedly short")
    # Python 3.11 briefly delegated mtime=0 compression to zlib, which could
    # write a platform-specific gzip OS byte. Pin it so CI and local sync agree.
    return gzipped[:9] + b"\xff" + gzipped[10:]


def request(url: str) -> urllib.request.Request:
    parsed = urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise SystemExit(f"refusing non-HTTPS download URL: {url}")
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "SSRVPN-geoip-sync",
    }
    token = os.environ.get("GITHUB_TOKEN")
    if token and parsed.hostname == "api.github.com":
        headers["Authorization"] = f"Bearer {token}"
    return urllib.request.Request(url, headers=headers)


def download(url: str, *, max_bytes: int) -> bytes:
    deadline = time.monotonic() + MAX_DOWNLOAD_SECONDS
    prepared_request = request(url)
    if urlsplit(url).hostname == "api.github.com":
        opener = urllib.request.build_opener(NoRedirectHandler())
        response_context = opener.open(prepared_request, timeout=10)
    else:
        response_context = urllib.request.urlopen(prepared_request, timeout=10)
    with response_context as response:
        content_length = response.headers.get("Content-Length") if hasattr(
            response, "headers"
        ) else None
        if content_length is not None and int(content_length) > max_bytes:
            raise SystemExit(f"download exceeds the {max_bytes} byte limit: {url}")
        content = bytearray()
        read_chunk = response.read1 if hasattr(response, "read1") else response.read
        while True:
            if time.monotonic() >= deadline:
                raise SystemExit(f"download exceeded its absolute deadline: {url}")
            chunk = read_chunk(
                min(DOWNLOAD_CHUNK_BYTES, max_bytes + 1 - len(content))
            )
            if not chunk:
                break
            content.extend(chunk)
            if len(content) > max_bytes:
                raise SystemExit(
                    f"download exceeds the {max_bytes} byte limit: {url}"
                )
            if time.monotonic() >= deadline:
                raise SystemExit(f"download exceeded its absolute deadline: {url}")
    return bytes(content)


def load_json_object(url: str) -> dict[str, object]:
    try:
        payload = json.loads(
            download(url, max_bytes=MAX_RELEASE_METADATA_BYTES).decode("utf-8")
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SystemExit(
            f"response is not a valid GitHub API JSON object: {url}"
        ) from error
    if not isinstance(payload, dict):
        raise SystemExit(f"response is not a GitHub API JSON object: {url}")
    return payload


def load_latest_release() -> dict[str, object]:
    return load_json_object(GITHUB_API_URL)


def _git_object(payload: dict[str, object], *, context: str) -> tuple[str, str]:
    value = payload.get("object")
    if not isinstance(value, dict):
        raise SystemExit(f"GitHub API {context} object is missing")
    object_type = value.get("type")
    object_sha = value.get("sha")
    if not isinstance(object_type, str) or not isinstance(object_sha, str):
        raise SystemExit(f"GitHub API {context} object is incomplete")
    if FULL_GIT_SHA_RE.fullmatch(object_sha) is None:
        raise SystemExit(f"GitHub API {context} object has an invalid SHA")
    return object_type, object_sha.lower()


def resolve_release_tag_commit(release: dict[str, object]) -> str:
    tag = release.get("tag_name")
    if not isinstance(tag, str) or not tag or tag.strip() != tag:
        raise SystemExit("upstream release tag_name is missing or invalid")

    ref_url = f"{GITHUB_API_BASE}/git/ref/tags/{quote(tag, safe='')}"
    ref = load_json_object(ref_url)
    if ref.get("ref") != f"refs/tags/{tag}":
        raise SystemExit("GitHub API release tag reference does not match tag_name")
    object_type, object_sha = _git_object(ref, context="release tag reference")

    visited: set[str] = set()
    for _ in range(MAX_TAG_PEEL_DEPTH):
        if object_type == "commit":
            return object_sha
        if object_type != "tag":
            raise SystemExit(
                f"upstream release tag does not resolve to a commit: {object_type}"
            )
        if object_sha in visited:
            raise SystemExit("upstream release tag contains a tag-object cycle")
        visited.add(object_sha)
        tag_object = load_json_object(f"{GITHUB_API_BASE}/git/tags/{object_sha}")
        if tag_object.get("sha") != object_sha:
            raise SystemExit("GitHub API annotated tag object SHA does not match request")
        object_type, object_sha = _git_object(
            tag_object,
            context="annotated tag",
        )

    raise SystemExit("upstream release tag nesting exceeds the verification limit")


def immutable_source_archive_url(commit_sha: str) -> str:
    if not isinstance(commit_sha, str) or FULL_GIT_SHA_RE.fullmatch(commit_sha) is None:
        raise SystemExit("source archive requires a full 40-character commit SHA")
    return f"{SOURCE_ARCHIVE_PREFIX}{commit_sha.lower()}.tar.gz"


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


def latest_release_identity(release: dict[str, object]) -> tuple[object, ...]:
    asset = find_asset(release, ASSET_NAME)
    checksum_asset = find_asset(release, CHECKSUM_ASSET_NAME)
    identity = (
        release.get("id"),
        release.get("tag_name"),
        asset.get("id"),
        asset.get("browser_download_url"),
        asset.get("digest"),
        checksum_asset.get("id"),
        checksum_asset.get("browser_download_url"),
        checksum_asset.get("digest"),
    )
    required = identity[:4] + identity[5:7]
    if any(value in (None, "") for value in required):
        raise SystemExit("upstream latest release identity is incomplete")
    return identity


def build_source_record(
    release: dict[str, object],
    asset: dict[str, object],
    upstream_hash: str,
    gzip_hash: str,
    release_commit_sha: str,
) -> str:
    source_archive_url = immutable_source_archive_url(release_commit_sha)
    mirror_asset_name = f"geoip.metadb-{gzip_hash}.gz"
    mirror_url = f"{MIRROR_URL_PREFIX}{mirror_asset_name}"
    return "\n".join(
        [
            f"Repo: {UPSTREAM_REPO}",
            f"Release ID: {release.get('id', '')}",
            f"Release tag: {release.get('tag_name', '')}",
            f"Release tag commit SHA: {release_commit_sha.lower()}",
            f"Immutable source archive: {source_archive_url}",
            f"Release name: {release.get('name', '')}",
            f"Asset ID: {asset.get('id', '')}",
            f"Asset URL: {asset.get('url', '')}",
            f"Upstream SHA256: {upstream_hash}",
            f"Bundled gzip SHA256: {gzip_hash}",
            f"Mirror repo: {MIRROR_REPO}",
            f"Mirror release tag: {MIRROR_RELEASE_TAG}",
            f"Mirror asset name: {mirror_asset_name}",
            f"Mirror URL: {mirror_url}",
            "",
        ],
    )


def sync(check: bool) -> int:
    release = load_latest_release()
    initial_identity = latest_release_identity(release)
    release_commit_sha = resolve_release_tag_commit(release)
    asset = find_asset(release, ASSET_NAME)
    checksum_asset = find_asset(release, CHECKSUM_ASSET_NAME)

    asset_url = str(asset["browser_download_url"])
    checksum_url = str(checksum_asset["browser_download_url"])
    expected_hash = parse_checksum(
        download(checksum_url, max_bytes=MAX_CHECKSUM_BYTES)
    )
    api_hash = asset_digest(asset)
    if api_hash is not None and api_hash != expected_hash:
        raise SystemExit(
            f"GitHub API digest {api_hash} does not match {CHECKSUM_ASSET_NAME} {expected_hash}",
        )

    raw = download(asset_url, max_bytes=MAX_GEOIP_BYTES)
    actual_hash = sha256(raw)
    if actual_hash != expected_hash:
        raise SystemExit(
            f"{ASSET_NAME} SHA256 mismatch: expected {expected_hash}, got {actual_hash}",
        )

    gzipped = stable_gzip(raw)
    gzip_hash = sha256(gzipped)
    source_record = build_source_record(
        release,
        asset,
        actual_hash,
        gzip_hash,
        release_commit_sha,
    )

    final_release = load_latest_release()
    if latest_release_identity(final_release) != initial_identity:
        raise SystemExit("upstream latest changed during verification")
    final_release_commit_sha = resolve_release_tag_commit(final_release)
    if final_release_commit_sha != release_commit_sha:
        raise SystemExit("upstream release tag commit changed during verification")

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
            if path.exists():
                print(f"geoip sync: local SHA256 {sha256(path.read_bytes())}")
            else:
                print("geoip sync: local file missing")
        if source_mismatch:
            print(f"geoip sync: stale {SOURCE_RECORD.relative_to(ROOT)}")
        if mismatches or source_mismatch:
            print(f"geoip sync: release tag {release.get('tag_name', '')}")
            print(f"geoip sync: release name {release.get('name', '')}")
            print(f"geoip sync: upstream {actual_hash}")
            print(f"geoip sync: expected bundled gzip {gzip_hash}")
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
