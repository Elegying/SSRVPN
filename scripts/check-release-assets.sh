#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-latest}"
REPO="${SSRVPN_REPO:-Elegying/SSRVPN}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required to verify release assets" >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/ssrvpn-release-check.XXXXXX")"
cleanup() {
  rm -r "$work_dir"
}
trap cleanup EXIT

release_endpoint="repos/$REPO/releases/latest"
if [ "$TAG" != latest ]; then
  release_endpoint="repos/$REPO/releases/tags/$TAG"
fi

fetch_release_metadata() {
  local attempt
  for attempt in 1 2 3; do
    if gh api "$release_endpoint" > "$work_dir/release.json"; then
      return 0
    fi
    if [ "$attempt" -lt 3 ]; then
      sleep "$attempt"
    fi
  done
  return 1
}

fetch_release_metadata
release_tag="$("$PYTHON_BIN" - "$work_dir/release.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as release_file:
    release = json.load(release_file)
print(release.get("tag_name") or "")
PY
)"
if [ -z "$release_tag" ]; then
  echo "release metadata has no tag_name" >&2
  exit 1
fi

download_verification_assets() {
  local attempt
  for attempt in 1 2 3; do
    if gh release download "$release_tag" \
      --repo "$REPO" \
      --dir "$work_dir/assets" \
      --pattern '*.sha256' \
      --pattern 'SSRVPN-release-provenance.json' \
      --clobber; then
      return 0
    fi
    if [ "$attempt" -lt 3 ]; then
      sleep "$attempt"
    fi
  done
  return 1
}

mkdir "$work_dir/assets"
download_verification_assets

"$PYTHON_BIN" - "$work_dir/release.json" "$work_dir/assets" <<'PY'
import json
import os
import re
import sys

release_path, asset_directory = sys.argv[1], sys.argv[2]
with open(release_path, encoding="utf-8") as release_file:
    release = json.load(release_file)

required = {
    "SSRVPN.apk",
    "SSRVPN.apk.sha256",
    "SSRVPN.dmg",
    "SSRVPN.dmg.sha256",
    "SSRVPN_Setup.exe",
    "SSRVPN_Setup.exe.sha256",
    "SSRVPN-release-provenance.json",
}
allowed_retired = set()
if os.environ.get("SSRVPN_ALLOW_RETIRED_WINDOWS_ZIP") == "1":
    allowed_retired = {"SSRVPN.zip", "SSRVPN.zip.sha256"}
assets = {asset.get("name"): asset for asset in release.get("assets", [])}
missing = sorted(required - set(assets))
if missing:
    raise SystemExit(f"missing release assets: {', '.join(missing)}")
unexpected = sorted(set(assets) - required - allowed_retired)
if unexpected:
    raise SystemExit(f"unexpected release assets: {', '.join(unexpected)}")

empty = sorted(name for name in required if int(assets[name].get("size") or 0) <= 0)
if empty:
    raise SystemExit(f"empty release assets: {', '.join(empty)}")

oversized = sorted(
    name
    for name in required
    if int(assets[name].get("size") or 0)
    > (
        64 * 1024
        if name.endswith(".sha256") or name.endswith(".json")
        else 300 * 1024 * 1024
    )
)
if oversized:
    raise SystemExit(f"oversized release assets: {', '.join(oversized)}")

hash_pattern = re.compile(r"\b([0-9a-fA-F]{64})\b")
for artifact_name in (
    "SSRVPN.apk",
    "SSRVPN.dmg",
    "SSRVPN_Setup.exe",
):
    digest = str(assets[artifact_name].get("digest") or "")
    if not digest.startswith("sha256:") or not hash_pattern.fullmatch(digest[7:]):
        raise SystemExit(f"missing SHA256 API digest: {artifact_name}")

    checksum_path = os.path.join(
        asset_directory,
        f"{artifact_name}.sha256",
    )
    with open(checksum_path, encoding="ascii", errors="replace") as checksum_file:
        checksum_text = checksum_file.read(4096)
    checksum_match = hash_pattern.search(checksum_text)
    if checksum_match is None:
        raise SystemExit(f"invalid checksum file: {artifact_name}.sha256")
    if checksum_match.group(1).lower() != digest[7:].lower():
        raise SystemExit(f"checksum does not match GitHub digest: {artifact_name}")

provenance_path = os.path.join(
    asset_directory,
    "SSRVPN-release-provenance.json",
)
with open(provenance_path, encoding="utf-8") as provenance_file:
    provenance = json.load(provenance_file)
if provenance.get("schema") != 1 or provenance.get("tag") != release.get("tag_name"):
    raise SystemExit("release provenance tag/schema mismatch")
if re.fullmatch(r"[0-9a-f]{40}", str(provenance.get("commit") or "")) is None:
    raise SystemExit("release provenance commit is invalid")
provenance_assets = provenance.get("assets")
if not isinstance(provenance_assets, dict):
    raise SystemExit("release provenance asset map is missing")
for artifact_name in (
    "SSRVPN.apk",
    "SSRVPN.dmg",
    "SSRVPN_Setup.exe",
):
    api_digest = str(assets[artifact_name].get("digest") or "").removeprefix(
        "sha256:"
    )
    if provenance_assets.get(artifact_name) != api_digest:
        raise SystemExit(f"release provenance digest mismatch: {artifact_name}")

print(
    f"Release {release.get('tag_name')} has all required SSRVPN assets "
    "with matching SHA256 checksums and provenance."
)
PY
