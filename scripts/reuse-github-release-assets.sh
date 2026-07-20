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
release_pages_json="$work_dir/release-pages.json"
api_error="$work_dir/api-error.log"
asset_map="$work_dir/assets.tsv"

github_api_retry() {
  local stdout_file="$1"
  local stderr_file="$2"
  shift 2
  local max_attempts="${GITHUB_API_RETRY_ATTEMPTS:-4}"
  local base_delay="${GITHUB_API_RETRY_BASE_SECONDS:-1}"
  local attempt=1
  local delay

  if [[ ! "$max_attempts" =~ ^[1-9][0-9]*$ ]] || [ "$max_attempts" -gt 10 ]; then
    echo "GITHUB_API_RETRY_ATTEMPTS must be between 1 and 10" >&2
    return 2
  fi
  if [[ ! "$base_delay" =~ ^[0-9]+$ ]] || [ "$base_delay" -gt 30 ]; then
    echo "GITHUB_API_RETRY_BASE_SECONDS must be between 0 and 30" >&2
    return 2
  fi

  while true; do
    : >"$stdout_file"
    : >"$stderr_file"
    if gh api "$@" >"$stdout_file" 2>"$stderr_file"; then
      return 0
    fi
    if [ "$attempt" -ge "$max_attempts" ] ||
      ! grep -Eqi \
        'HTTP (408|429|500|502|503|504)|rate.?limit|timed? ?out|timeout|connection (reset|refused)|temporar(il)?y unavailable|TLS handshake|unexpected EOF' \
        "$stderr_file"; then
      return 1
    fi
    delay=$((base_delay * (1 << (attempt - 1))))
    [ "$delay" -le 30 ] || delay=30
    echo "Transient GitHub API failure (attempt $attempt/$max_attempts); retrying in ${delay}s" >&2
    sleep "$delay"
    attempt=$((attempt + 1))
  done
}

if ! github_api_retry "$release_json" "$api_error" \
  "repos/$repo/releases/tags/$tag"; then
  if grep -Eq 'HTTP 404|Not Found.*404|404.*Not Found' "$api_error"; then
    if ! github_api_retry "$release_pages_json" "$api_error" \
      --paginate --slurp "repos/$repo/releases?per_page=100"; then
      cat "$api_error" >&2
      echo "Unable to inspect GitHub release drafts for $tag" >&2
      exit 1
    fi
    selection="$(python3 - "$release_pages_json" "$release_json" "$tag" <<'PY'
import json
import sys
from pathlib import Path

pages_path = Path(sys.argv[1])
release_path = Path(sys.argv[2])
expected_tag = sys.argv[3]
payload = json.loads(pages_path.read_text(encoding="utf-8"))
if not isinstance(payload, list):
    raise SystemExit("GitHub release listing is not a JSON array")
if any(not isinstance(page, list) for page in payload):
    raise SystemExit("GitHub paginated release response is invalid")
releases = [release for page in payload for release in page]
matches = [
    release
    for release in releases
    if isinstance(release, dict) and release.get("tag_name") == expected_tag
]
if not matches:
    print("missing")
elif len(matches) == 1:
    release_path.write_text(json.dumps(matches[0]), encoding="utf-8")
    print("found")
else:
    raise SystemExit(f"Multiple GitHub releases use tag {expected_tag}")
PY
)"
    if [ "$selection" = missing ]; then
      echo "exists=false" >>"$output_file"
      exit 0
    fi
  else
    cat "$api_error" >&2
    echo "Unable to inspect an existing GitHub release for $tag" >&2
    exit 1
  fi
fi

inspection="$(python3 - "$release_json" "$tag" "$asset_map" <<'PY'
import json
import re
import sys
from pathlib import Path

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
expected_tag = sys.argv[2]
asset_map_path = Path(sys.argv[3])
if not isinstance(release, dict):
    raise SystemExit("GitHub release response is not a JSON object")
if release.get("tag_name") != expected_tag:
    raise SystemExit("GitHub release tag does not match the requested tag")
release_id = release.get("id")
if isinstance(release_id, bool) or not isinstance(release_id, int) or release_id <= 0:
    raise SystemExit("GitHub release ID is invalid")
raw_assets = release.get("assets")
if not isinstance(raw_assets, list):
    raise SystemExit("GitHub release asset list is invalid")
assets = {}
duplicate_names = set()
invalid_entries = False
for asset in raw_assets:
    if not isinstance(asset, dict) or not isinstance(asset.get("name"), str):
        invalid_entries = True
        continue
    name = asset["name"]
    if name in assets:
        duplicate_names.add(name)
    assets[name] = asset
missing = sorted(required - set(assets))
unexpected = sorted(set(assets) - required)
empty = []
oversized = []
unfinished = []
invalid_metadata = bool(duplicate_names or invalid_entries)
asset_ids = set()
digest_pattern = re.compile(r"sha256:[0-9a-f]{64}\Z")
for name in required & set(assets):
    asset = assets[name]
    size = asset.get("size")
    asset_id = asset.get("id")
    digest = asset.get("digest")
    if asset.get("state") != "uploaded":
        unfinished.append(name)
        continue
    if isinstance(size, bool) or not isinstance(size, int):
        invalid_metadata = True
    elif size <= 0:
        empty.append(name)
    elif size > limits[name]:
        oversized.append(name)
    if (
        isinstance(asset_id, bool)
        or not isinstance(asset_id, int)
        or asset_id <= 0
        or asset_id in asset_ids
    ):
        invalid_metadata = True
    else:
        asset_ids.add(asset_id)
    if not isinstance(digest, str) or digest_pattern.fullmatch(digest) is None:
        invalid_metadata = True
if not isinstance(release.get("draft"), bool) or not isinstance(
    release.get("prerelease"), bool
):
    raise SystemExit("GitHub release visibility metadata is invalid")
draft = release["draft"]
prerelease = release["prerelease"]
visibility = "prerelease" if prerelease else ("draft" if draft else "public")
if oversized:
    print(f"invalid\t{visibility}\t{release_id}\toversized asset")
elif invalid_metadata and not (missing or unexpected or empty or unfinished):
    print(f"invalid\t{visibility}\t{release_id}\tinvalid asset metadata")
elif missing or unexpected or empty or unfinished:
    print(f"incomplete\t{visibility}\t{release_id}\tincomplete asset set")
else:
    asset_map_path.write_text(
        "".join(f"{name}\t{assets[name]['id']}\n" for name in sorted(required)),
        encoding="utf-8",
    )
    print(f"complete\t{visibility}\t{release_id}\tverified asset metadata")
PY
)"
IFS=$'\t' read -r state visibility release_id inspection_reason <<<"$inspection"

if [ "$state" = invalid ]; then
  echo "GitHub release $tag has $inspection_reason; refusing to download it" >&2
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
    delete_response="$work_dir/delete-response.json"
    if ! github_api_retry "$delete_response" "$api_error" \
      --method DELETE "repos/$repo/releases/$release_id"; then
      cat "$api_error" >&2
      echo "Unable to delete incomplete GitHub release draft $release_id" >&2
      exit 1
    fi
    echo "exists=false" >>"$output_file"
    exit 0
  fi
  echo "Public GitHub release $tag is incomplete; refusing to replace it" >&2
  exit 1
fi

download_dir="$work_dir/download"
mkdir -p "$download_dir"
while IFS=$'\t' read -r asset_name asset_id; do
  case "$asset_name" in
    SSRVPN.apk | SSRVPN.apk.sha256 | SSRVPN.dmg | SSRVPN.dmg.sha256 | \
      SSRVPN_Setup.exe | SSRVPN_Setup.exe.sha256 | SSRVPN-release-provenance.json) ;;
    *)
      echo "Refusing to download unexpected GitHub asset: $asset_name" >&2
      exit 1
      ;;
  esac
  if ! github_api_retry "$download_dir/$asset_name" "$api_error" \
    -H "Accept: application/octet-stream" \
    "repos/$repo/releases/assets/$asset_id"; then
    cat "$api_error" >&2
    echo "Unable to download GitHub release asset $asset_name" >&2
    exit 1
  fi
done <"$asset_map"

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

for name, asset in assets.items():
    downloaded = download_path / name
    if not downloaded.is_file():
        raise SystemExit(f"Downloaded release is missing {name}")
    if asset["digest"] != f"sha256:{sha256(downloaded)}":
        raise SystemExit(f"GitHub digest mismatch for {name}")

for name in ("SSRVPN.apk", "SSRVPN.dmg", "SSRVPN_Setup.exe"):
    artifact = download_path / name
    checksum_file = download_path / f"{name}.sha256"
    if not artifact.is_file() or not checksum_file.is_file():
        raise SystemExit(f"Downloaded release is missing {name} or its checksum")
    actual = sha256(artifact)
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

{
  echo "exists=true"
  echo "draft=$([ "$visibility" = draft ] && echo true || echo false)"
  echo "prerelease=false"
} >>"$output_file"
echo "Reused verified canonical assets from GitHub release $tag ($visibility)."
