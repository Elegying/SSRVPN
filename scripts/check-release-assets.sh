#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-latest}"
REPO="${SSRVPN_REPO:-Elegying/SSRVPN}"

python3 - "$REPO" "$TAG" <<'PY'
import json
import os
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

print(f"Release {release.get('tag_name')} has all required SSRVPN assets.")
PY
