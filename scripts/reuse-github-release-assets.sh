#!/usr/bin/env bash
set -euo pipefail

artifact_root="${1:?usage: reuse-github-release-assets.sh <artifact-root>}"
tag="${GITHUB_REF_NAME:-${GITHUB_REF#refs/tags/}}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
output_file="${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if [[ ! "$tag" =~ ^v[0-9]+(\.[0-9]+){1,3}$ ]]; then
  echo "Invalid release tag: $tag" >&2
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
release_json="$work_dir/release.json"
api_error="$work_dir/api-error.log"

if ! gh api "repos/$repo/releases/tags/$tag" >"$release_json" 2>"$api_error"; then
  if grep -Eq 'HTTP 404|Not Found.*404|404.*Not Found' "$api_error"; then
    echo "exists=false" >>"$output_file"
    exit 0
  fi
  cat "$api_error" >&2
  echo "Unable to inspect an existing GitHub release for $tag" >&2
  exit 1
fi

inspection="$(python3 - "$release_json" <<'PY'
import json
import sys

required = {
    "SSRVPN.apk",
    "SSRVPN.apk.sha256",
    "SSRVPN.dmg",
    "SSRVPN.dmg.sha256",
    "SSRVPN_Setup.exe",
    "SSRVPN_Setup.exe.sha256",
    "SSRVPN-release-provenance.json",
}
limits = {
    name: (
        64 * 1024
        if name.endswith(".sha256") or name.endswith(".json")
        else 300 * 1024 * 1024
    )
    for name in required
}
release = json.load(open(sys.argv[1], encoding="utf-8"))
assets = {
    asset.get("name"): asset
    for asset in release.get("assets", [])
    if isinstance(asset, dict) and isinstance(asset.get("name"), str)
}
missing = sorted(required - set(assets))
unexpected = sorted(set(assets) - required)
empty = sorted(
    name for name in required if name in assets and int(assets[name].get("size") or 0) <= 0
)
oversized = sorted(
    name
    for name in required
    if name in assets and int(assets[name].get("size") or 0) > limits[name]
)
draft = release.get("draft") is True
prerelease = release.get("prerelease") is True
visibility = "draft" if draft else ("prerelease" if prerelease else "public")
if oversized:
    print("invalid\t" + visibility)
elif missing or unexpected or empty:
    print("incomplete\t" + visibility)
else:
    print("complete\t" + visibility)
PY
)"
state="${inspection%%$'\t'*}"
visibility="${inspection#*$'\t'}"

if [ "$state" = invalid ]; then
  echo "GitHub release $tag contains an oversized asset; refusing to download it" >&2
  exit 1
fi
if [ "$visibility" = prerelease ]; then
  echo "GitHub release $tag is a prerelease; refusing to promote it" >&2
  exit 1
fi
if [ "$state" != complete ]; then
  if [ "$visibility" = draft ]; then
    # A failed first upload may leave a partial draft. It has never been public,
    # so delete only the draft release and keep the immutable Git tag.
    gh release delete "$tag" --repo "$repo" --yes
    echo "exists=false" >>"$output_file"
    exit 0
  fi
  echo "Public GitHub release $tag is incomplete; refusing to replace it" >&2
  exit 1
fi

download_dir="$work_dir/download"
mkdir -p "$download_dir"
gh release download "$tag" --repo "$repo" --dir "$download_dir" \
  --pattern 'SSRVPN.apk' --pattern 'SSRVPN.apk.sha256' \
  --pattern 'SSRVPN.dmg' --pattern 'SSRVPN.dmg.sha256' \
  --pattern 'SSRVPN_Setup.exe' --pattern 'SSRVPN_Setup.exe.sha256' \
  --pattern 'SSRVPN-release-provenance.json'

python3 - "$release_json" "$download_dir" "$tag" "${GITHUB_SHA:?GITHUB_SHA is required}" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

release_path = Path(sys.argv[1])
download_path = Path(sys.argv[2])
expected_tag, expected_commit = sys.argv[3:]
release = json.loads(release_path.read_text(encoding="utf-8"))
assets = {asset["name"]: asset for asset in release["assets"]}
sha_re = re.compile(r"\b([0-9a-fA-F]{64})\b")

def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

for name in ("SSRVPN.apk", "SSRVPN.dmg", "SSRVPN_Setup.exe"):
    artifact = download_path / name
    checksum_file = download_path / f"{name}.sha256"
    if not artifact.is_file() or not checksum_file.is_file():
        raise SystemExit(f"Downloaded release is missing {name} or its checksum")
    actual = sha256(artifact)
    api_digest = str(assets[name].get("digest") or "")
    if api_digest != f"sha256:{actual}":
        raise SystemExit(f"GitHub digest mismatch for {name}")
    match = sha_re.search(checksum_file.read_text(encoding="ascii"))
    if match is None or match.group(1).lower() != actual:
        raise SystemExit(f"Checksum mismatch for {name}")

provenance = json.loads(
    (download_path / "SSRVPN-release-provenance.json").read_text(encoding="utf-8")
)
if provenance.get("schema") != 1:
    raise SystemExit("Release provenance schema is invalid")
if provenance.get("tag") != expected_tag or provenance.get("commit") != expected_commit:
    raise SystemExit("Release provenance does not match the tag commit")
provenance_assets = provenance.get("assets")
if not isinstance(provenance_assets, dict):
    raise SystemExit("Release provenance asset map is missing")
for name in ("SSRVPN.apk", "SSRVPN.dmg", "SSRVPN_Setup.exe"):
    if provenance_assets.get(name) != sha256(download_path / name):
        raise SystemExit(f"Release provenance mismatch for {name}")
PY

apksigner="$(find "${ANDROID_HOME:?ANDROID_HOME is required}/build-tools" \
  -name apksigner -type f | sort -V | tail -1)"
if [ -z "$apksigner" ] || [ ! -x "$apksigner" ]; then
  echo "apksigner not found in Android SDK build-tools" >&2
  exit 1
fi
if [ -z "${ANDROID_RELEASE_CERT_SHA256:-}" ]; then
  echo "ANDROID_RELEASE_CERT_SHA256 is not configured" >&2
  exit 1
fi
cert_output="$("$apksigner" verify --print-certs "$download_dir/SSRVPN.apk")"
actual_cert="$(printf '%s\n' "$cert_output" |
  sed -n 's/^.*certificate SHA-256 digest: //p' |
  head -1 | tr -d ':' | tr '[:upper:]' '[:lower:]')"
expected_cert="$(printf '%s' "$ANDROID_RELEASE_CERT_SHA256" |
  tr -d ':' | tr '[:upper:]' '[:lower:]')"
if [ -z "$actual_cert" ] || [ "$actual_cert" != "$expected_cert" ]; then
  echo "APK signing certificate mismatch for existing GitHub release" >&2
  exit 1
fi

install -m 0644 "$download_dir/SSRVPN.apk" "$artifact_root/android/SSRVPN.apk"
install -m 0644 "$download_dir/SSRVPN.apk.sha256" "$artifact_root/android/SSRVPN.apk.sha256"
install -m 0644 "$download_dir/SSRVPN.dmg" "$artifact_root/macos/SSRVPN.dmg"
install -m 0644 "$download_dir/SSRVPN.dmg.sha256" "$artifact_root/macos/SSRVPN.dmg.sha256"
install -m 0644 "$download_dir/SSRVPN_Setup.exe" "$artifact_root/windows/SSRVPN_Setup.exe"
install -m 0644 "$download_dir/SSRVPN_Setup.exe.sha256" "$artifact_root/windows/SSRVPN_Setup.exe.sha256"

echo "exists=true" >>"$output_file"
echo "draft=$([ "$visibility" = draft ] && echo true || echo false)" >>"$output_file"
echo "prerelease=false" >>"$output_file"
echo "Reused verified canonical assets from GitHub release $tag ($visibility)."
