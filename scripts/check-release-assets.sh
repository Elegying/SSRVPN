#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-latest}"
REPO="${SSRVPN_REPO:-Elegying/SSRVPN}"

python3 - "$REPO" "$TAG" <<'PY'
import json
import os
import re
import sys
import urllib.request

repo, tag = sys.argv[1], sys.argv[2]
url = f"https://api.github.com/repos/{repo}/releases/latest"
if tag != "latest":
    url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"

headers = {
    "Accept": "application/vnd.github+json",
    "User-Agent": "SSRVPN-release-check",
}
token = os.environ.get("GITHUB_TOKEN")
if token:
    headers["Authorization"] = f"Bearer {token}"
request = urllib.request.Request(url, headers=headers)
with urllib.request.urlopen(request, timeout=20) as response:
    release = json.load(response)

required = {
    "SSRVPN.apk",
    "SSRVPN.apk.sha256",
    "SSRVPN.dmg",
    "SSRVPN.dmg.sha256",
    "SSRVPN_Setup.exe",
    "SSRVPN_Setup.exe.sha256",
    "SSRVPN.zip",
    "SSRVPN.zip.sha256",
}
assets = {asset.get("name"): asset for asset in release.get("assets", [])}
missing = sorted(required - set(assets))
if missing:
    raise SystemExit(f"missing release assets: {', '.join(missing)}")

empty = sorted(name for name in required if int(assets[name].get("size") or 0) <= 0)
if empty:
    raise SystemExit(f"empty release assets: {', '.join(empty)}")

hash_pattern = re.compile(r"\b([0-9a-fA-F]{64})\b")
for artifact_name in (
    "SSRVPN.apk",
    "SSRVPN.dmg",
    "SSRVPN_Setup.exe",
    "SSRVPN.zip",
):
    digest = str(assets[artifact_name].get("digest") or "")
    if not digest.startswith("sha256:") or not hash_pattern.fullmatch(digest[7:]):
        raise SystemExit(f"missing SHA256 API digest: {artifact_name}")

    checksum_asset = assets[f"{artifact_name}.sha256"]
    checksum_request = urllib.request.Request(
        str(checksum_asset["browser_download_url"]),
        headers=headers,
    )
    with urllib.request.urlopen(checksum_request, timeout=20) as response:
        checksum_text = response.read(4096).decode("ascii", errors="replace")
    checksum_match = hash_pattern.search(checksum_text)
    if checksum_match is None:
        raise SystemExit(f"invalid checksum file: {artifact_name}.sha256")
    if checksum_match.group(1).lower() != digest[7:].lower():
        raise SystemExit(f"checksum does not match GitHub digest: {artifact_name}")

print(
    f"Release {release.get('tag_name')} has all required SSRVPN assets "
    "with matching SHA256 checksums."
)
PY
