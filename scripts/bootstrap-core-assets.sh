#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "core asset bootstrap failed: $*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

source_field() {
  local source_file="$1"
  local field="$2"
  awk -F': ' -v field="$field" '$1 == field { print $2; exit }' "$source_file"
}

require_field() {
  local source_file="$1"
  local field="$2"
  local value
  value="$(source_field "$source_file" "$field")"
  test -n "$value" || fail "$source_file is missing $field"
  printf '%s' "$value"
}

asset_matches() {
  local path="$1"
  local expected="$2"
  test -f "$path" && test "$(sha256_file "$path")" = "$expected"
}

download_verified() {
  local url="$1"
  local expected="$2"
  local output="$3"
  local label="$4"
  local max_bytes="$5"

  case "$url" in
    https://github.com/* | https://api.github.com/*) ;;
    *) fail "$label uses an unapproved download host: $url" ;;
  esac

  local curl_args=(
    --fail
    --location
    --header 'Accept: application/octet-stream'
    --proto '=https'
    --proto-redir '=https'
    --retry 3
    --retry-all-errors
    --connect-timeout 15
    --max-time 300
    --max-filesize "$max_bytes"
    --output "$output"
  )
  if [[ "$url" == https://api.github.com/* && -n "${GITHUB_TOKEN:-}" ]]; then
    curl_args+=(--oauth2-bearer "${GITHUB_TOKEN}")
  fi

  curl "${curl_args[@]}" "$url"

  local actual_size
  actual_size="$(wc -c <"$output" | tr -d '[:space:]')"
  test "$actual_size" -le "$max_bytes" ||
    fail "$label exceeds the $max_bytes byte limit"

  local actual
  actual="$(sha256_file "$output")"
  test "$actual" = "$expected" ||
    fail "$label SHA256 mismatch: expected $expected got $actual"
}

verify_geoip_payload() {
  local archive="$1"
  local expected_gzip_hash="$2"
  local expected_raw_hash="$3"
  local max_raw_bytes="$4"
  local actual_gzip_hash

  actual_gzip_hash="$(sha256_file "$archive")"
  test "$actual_gzip_hash" = "$expected_gzip_hash" ||
    fail "GeoIP mirror gzip SHA256 mismatch: expected $expected_gzip_hash got $actual_gzip_hash"

  python3 - "$archive" "$expected_raw_hash" "$max_raw_bytes" <<'PY'
import gzip
import hashlib
import sys
from pathlib import Path

archive_path, expected_hash, max_bytes_raw = sys.argv[1:]
max_bytes = int(max_bytes_raw)
digest = hashlib.sha256()
total = 0
try:
    with gzip.open(Path(archive_path), "rb") as source:
        while True:
            chunk = source.read(min(64 * 1024, max_bytes + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > max_bytes:
                raise SystemExit(
                    f"GeoIP mirror raw payload exceeds the {max_bytes} byte limit"
                )
            digest.update(chunk)
except (EOFError, OSError) as error:
    raise SystemExit(f"GeoIP mirror is not a valid gzip: {error}") from error

actual_hash = digest.hexdigest()
if actual_hash != expected_hash:
    raise SystemExit(
        f"GeoIP mirror raw SHA256 mismatch: expected {expected_hash} got {actual_hash}"
    )
PY
}

extract_zip_member_bounded() {
  local archive="$1"
  local member="$2"
  local output="$3"
  local max_bytes="$4"
  local label="$5"
  python3 - "$archive" "$member" "$output" "$max_bytes" "$label" <<'PY'
import stat
import sys
import zipfile
from pathlib import Path

archive_path, member, output_path, max_bytes_raw, label = sys.argv[1:]
max_bytes = int(max_bytes_raw)
with zipfile.ZipFile(archive_path) as archive:
    matches = [info for info in archive.infolist() if info.filename == member]
    if len(matches) != 1:
        raise SystemExit(f"{label} must contain exactly one {member}")
    info = matches[0]
    if stat.S_ISLNK(info.external_attr >> 16):
        raise SystemExit(f"{label} member {member} must not be a symlink")
    if info.file_size > max_bytes:
        raise SystemExit(f"{label} member exceeds the {max_bytes} byte limit")
    total = 0
    with archive.open(info) as source, Path(output_path).open("wb") as target:
        while True:
            chunk = source.read(min(1024 * 1024, max_bytes + 1 - total))
            if not chunk:
                break
            total += len(chunk)
            if total > max_bytes:
                raise SystemExit(
                    f"{label} member exceeds the {max_bytes} byte limit"
                )
            target.write(chunk)
    if total != info.file_size:
        raise SystemExit(f"{label} member size changed during extraction")
PY
}

install_verified() {
  local source="$1"
  local destination="$2"
  local expected="$3"
  local label="$4"
  local actual

  actual="$(sha256_file "$source")"
  test "$actual" = "$expected" ||
    fail "$label SHA256 mismatch before install: expected $expected got $actual"

  mkdir -p "$(dirname "$destination")"
  cp "$source" "${destination}.tmp.$$"
  mv -f "${destination}.tmp.$$" "$destination"
  echo "installed $label"
}

for command in curl gzip python3; do
  command -v "$command" >/dev/null 2>&1 || fail "$command is required"
done

android_source="SSRVPN_Android/assets/libgojni-source.txt"
geo_source="docs/GEOIP_SOURCE.txt"
macos_source="SSRVPN_MacOS/assets/AtlasCore-source.txt"
windows_source="SSRVPN_Windows/assets/mihomo-source.txt"

apk_url="$(require_field "$android_source" 'Container URL')"
apk_hash="$(require_field "$android_source" 'Container SHA256')"
android_member="$(require_field "$android_source" 'Library member')"
android_hash="$(require_field "$android_source" 'Library SHA256')"
geo_mirror_repo="$(require_field "$geo_source" 'Mirror repo')"
geo_mirror_tag="$(require_field "$geo_source" 'Mirror release tag')"
geo_mirror_name="$(require_field "$geo_source" 'Mirror asset name')"
geo_url="$(require_field "$geo_source" 'Mirror URL')"
geo_raw_hash="$(require_field "$geo_source" 'Upstream SHA256')"
geo_gzip_hash="$(require_field "$geo_source" 'Bundled gzip SHA256')"
expected_geo_name="geoip.metadb-${geo_gzip_hash}.gz"
expected_geo_url="https://github.com/Elegying/SSRVPN/releases/download/core-assets-v1/${expected_geo_name}"
test "$geo_mirror_repo" = "Elegying/SSRVPN" ||
  fail "GeoIP mirror repo must be Elegying/SSRVPN"
test "$geo_mirror_tag" = "core-assets-v1" ||
  fail "GeoIP mirror release tag must be core-assets-v1"
test "$geo_mirror_name" = "$expected_geo_name" ||
  fail "GeoIP mirror asset must be content-addressed as $expected_geo_name"
test "$geo_url" = "$expected_geo_url" ||
  fail "GeoIP Mirror URL must be $expected_geo_url"

android_asset="SSRVPN_Android/android/app/src/main/jniLibs/arm64-v8a/libgojni.so"
geo_assets=(
  SSRVPN_Android/assets/geoip.metadb.gz
  SSRVPN_MacOS/assets/geoip.metadb.gz
  SSRVPN_Windows/assets/geoip.metadb.gz
)

temp_dir="$(mktemp -d "${TMPDIR:-/tmp}/ssrvpn-core-assets.XXXXXX")"
cleanup() {
  local status=$?
  trap - EXIT
  rm -rf "$temp_dir"
  exit "$status"
}
trap cleanup EXIT

if ! asset_matches "$android_asset" "$android_hash"; then
  apk="$temp_dir/SSRVPN.apk"
  download_verified \
    "$apk_url" "$apk_hash" "$apk" "Android bootstrap APK" $((512 * 1024 * 1024))

  extract_zip_member_bounded \
    "$apk" "$android_member" "$temp_dir/libgojni.so" \
    $((128 * 1024 * 1024)) "Android bootstrap APK"
  install_verified \
    "$temp_dir/libgojni.so" "$android_asset" "$android_hash" \
    "Android libgojni.so"
else
  echo "ok Android libgojni.so"
fi

need_geo=0
for geo_asset in "${geo_assets[@]}"; do
  asset_matches "$geo_asset" "$geo_gzip_hash" || need_geo=1
done
if [ "$need_geo" -eq 1 ]; then
  download_verified \
    "$geo_url" "$geo_gzip_hash" "$temp_dir/geoip.metadb.gz" \
    "GeoIP mirror asset" $((64 * 1024 * 1024))
  verify_geoip_payload \
    "$temp_dir/geoip.metadb.gz" "$geo_gzip_hash" "$geo_raw_hash" \
    $((64 * 1024 * 1024))
  for geo_asset in "${geo_assets[@]}"; do
    install_verified \
      "$temp_dir/geoip.metadb.gz" "$geo_asset" "$geo_gzip_hash" \
      "$geo_asset"
  done
else
  echo "ok GeoIP bootstrap assets"
fi

macos_url="$(require_field "$macos_source" 'Official asset URL')"
macos_gzip_hash="$(require_field "$macos_source" 'Official asset SHA256')"
macos_asset="SSRVPN_MacOS/assets/AtlasCore.gz"
if asset_matches "$macos_asset" "$macos_gzip_hash"; then
  echo "ok macOS AtlasCore.gz"
else
  download_verified \
    "$macos_url" "$macos_gzip_hash" "$temp_dir/AtlasCore.gz" \
    "macOS Mihomo archive" $((256 * 1024 * 1024))
  install_verified \
    "$temp_dir/AtlasCore.gz" "$macos_asset" "$macos_gzip_hash" \
    "macOS AtlasCore.gz"
fi

windows_url="$(require_field "$windows_source" 'Official asset URL')"
windows_zip_hash="$(require_field "$windows_source" 'Official asset SHA256')"
windows_member="$(require_field "$windows_source" 'Executable member')"
windows_hash="$(require_field "$windows_source" 'Executable SHA256')"
windows_asset="SSRVPN_Windows/assets/mihomo.exe"
if asset_matches "$windows_asset" "$windows_hash"; then
  echo "ok Windows mihomo.exe"
else
  download_verified \
    "$windows_url" "$windows_zip_hash" "$temp_dir/mihomo-windows.zip" \
    "Windows Mihomo archive" $((256 * 1024 * 1024))
  extract_zip_member_bounded \
    "$temp_dir/mihomo-windows.zip" "$windows_member" \
    "$temp_dir/mihomo.exe" $((128 * 1024 * 1024)) \
    "Windows Mihomo archive"
  install_verified \
    "$temp_dir/mihomo.exe" "$windows_asset" "$windows_hash" \
    "Windows mihomo.exe"
fi

bash scripts/verify-core-assets.sh
