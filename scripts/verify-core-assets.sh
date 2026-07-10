#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

fail() {
  echo "core asset check failed: $*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

source_hash() {
  local source_file="$1"
  local field="$2"
  awk -F': ' -v field="$field" '$1 == field { print $2; exit }' "$source_file"
}

check_file() {
  local path="$1"
  local expected="$2"
  local label="$3"

  test -f "$path" || fail "$label missing: $path"
  if head -n 1 "$path" | grep -q '^version https://git-lfs.github.com/spec/v1$'; then
    fail "$label is a Git LFS pointer, run scripts/bootstrap-core-assets.sh: $path"
  fi

  local actual
  actual="$(sha256_file "$path")"
  if [ "$actual" != "$expected" ]; then
    fail "$label SHA256 mismatch: expected $expected got $actual"
  fi
  echo "ok $label"
}

check_gzip_payload() {
  local path="$1"
  local expected="$2"
  local label="$3"
  local actual
  actual="$(gzip -cd "$path" | sha256_stdin)"
  if [ "$actual" != "$expected" ]; then
    fail "$label decompressed SHA256 mismatch: expected $expected got $actual"
  fi
  echo "ok $label decompressed"
}

check_file \
  "SSRVPN_Android/android/app/src/main/jniLibs/arm64-v8a/libgojni.so" \
  "$(source_hash SSRVPN_Android/assets/libgojni-source.txt 'Library SHA256')" \
  "Android libgojni.so"

check_file \
  "SSRVPN_Android/assets/geoip.metadb.gz" \
  "$(source_hash docs/GEOIP_SOURCE.txt 'Bundled gzip SHA256')" \
  "Android geoip.metadb.gz"

check_gzip_payload \
  "SSRVPN_Android/assets/geoip.metadb.gz" \
  "$(source_hash docs/GEOIP_SOURCE.txt 'Upstream SHA256')" \
  "Android geoip.metadb"

check_file \
  "SSRVPN_MacOS/assets/AtlasCore.gz" \
  "$(source_hash SSRVPN_MacOS/assets/AtlasCore-source.txt 'Bundled gzip SHA256')" \
  "macOS AtlasCore.gz"

check_gzip_payload \
  "SSRVPN_MacOS/assets/AtlasCore.gz" \
  "$(source_hash SSRVPN_MacOS/assets/AtlasCore-source.txt 'Executable SHA256')" \
  "macOS AtlasCore"

check_file \
  "SSRVPN_MacOS/assets/geoip.metadb.gz" \
  "$(source_hash docs/GEOIP_SOURCE.txt 'Bundled gzip SHA256')" \
  "macOS geoip.metadb.gz"

check_gzip_payload \
  "SSRVPN_MacOS/assets/geoip.metadb.gz" \
  "$(source_hash docs/GEOIP_SOURCE.txt 'Upstream SHA256')" \
  "macOS geoip.metadb"

check_file \
  "SSRVPN_Windows/assets/mihomo.exe" \
  "$(source_hash SSRVPN_Windows/assets/mihomo-source.txt 'Executable SHA256')" \
  "Windows mihomo.exe"

check_file \
  "SSRVPN_Windows/assets/geoip.metadb.gz" \
  "$(source_hash docs/GEOIP_SOURCE.txt 'Bundled gzip SHA256')" \
  "Windows geoip.metadb.gz"

check_gzip_payload \
  "SSRVPN_Windows/assets/geoip.metadb.gz" \
  "$(source_hash docs/GEOIP_SOURCE.txt 'Upstream SHA256')" \
  "Windows geoip.metadb"

echo "Core asset verification passed."
