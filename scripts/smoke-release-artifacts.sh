#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

allow_missing=0
if [[ "${1:-}" == "--allow-missing" ]]; then
  allow_missing=1
fi

missing() {
  if [[ "$allow_missing" -eq 1 ]]; then
    echo "smoke: skip $1, artifact not found"
    return 0
  fi
  echo "smoke: missing $1" >&2
  return 1
}

check_apk() {
  local apk=""
  for candidate in \
    SSRVPN_Android/SSRVPN.apk \
    SSRVPN_Android/build/app/outputs/flutter-apk/app-release.apk \
    SSRVPN_Android/build/app/outputs/apk/release/app-release.apk; do
    if [[ -f "$candidate" ]]; then
      apk="$candidate"
      break
    fi
  done
  [[ -n "$apk" ]] || { missing "Android APK"; return; }
  python3 - "$apk" <<'PY'
from pathlib import Path
import sys
import zipfile

apk = Path(sys.argv[1])
if apk.stat().st_size <= 1024 * 1024:
    raise SystemExit(f"APK too small: {apk}")
with zipfile.ZipFile(apk) as zf:
    names = set(zf.namelist())
    if "AndroidManifest.xml" not in names:
        raise SystemExit("APK missing AndroidManifest.xml")
    libs = [name for name in names if name.endswith("/libgojni.so")]
    if not libs:
        raise SystemExit("APK missing libgojni.so")
print(f"smoke: APK ok: {apk}")
PY
}

check_dmg() {
  local dmg=""
  for candidate in \
    SSRVPN_MacOS/SSRVPN.dmg \
    SSRVPN_MacOS/build/package_macos/SSRVPN-rw.dmg; do
    if [[ -f "$candidate" ]]; then
      dmg="$candidate"
      break
    fi
  done
  [[ -n "$dmg" ]] || { missing "macOS DMG"; return; }
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "smoke: skip DMG mount check on non-macOS"
    return 0
  fi
  hdiutil verify "$dmg" >/dev/null
  local MOUNT_DIR
  MOUNT_DIR="$(mktemp -d)"
  cleanup() {
    if mount | grep -qF "$MOUNT_DIR"; then
      hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$MOUNT_DIR"
  }
  trap cleanup RETURN
  hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$dmg" >/dev/null
  test -d "$MOUNT_DIR/SSRVPN.app"
  test -L "$MOUNT_DIR/Applications"
  test -f "$MOUNT_DIR/.background/background.png"
  test -f "$MOUNT_DIR/.DS_Store"
  grep -aFq "background.png" "$MOUNT_DIR/.DS_Store"
  test ! -e "$MOUNT_DIR/安装教程.txt"
  test ! -e "$MOUNT_DIR/使用教程.txt"
  local top_level_count
  top_level_count="$(find "$MOUNT_DIR" -mindepth 1 -maxdepth 1 \
    ! -name '.*' -print | wc -l | tr -d ' ')"
  [[ "$top_level_count" -eq 2 ]]
  echo "smoke: DMG ok: $dmg"
}

check_installer() {
  local installer=""
  for candidate in \
    SSRVPN_Windows/SSRVPN_Setup.exe \
    SSRVPN_Windows/build/SSRVPN_Setup.exe; do
    if [[ -f "$candidate" ]]; then
      installer="$candidate"
      break
    fi
  done
  [[ -n "$installer" ]] || { missing "Windows installer"; return; }
  python3 - "$installer" <<'PY'
from pathlib import Path
import hashlib
import re
import sys

installer = Path(sys.argv[1])
if installer.stat().st_size <= 1024 * 1024:
    raise SystemExit(f"Installer too small: {installer}")
with installer.open("rb") as stream:
    if stream.read(2) != b"MZ":
        raise SystemExit(f"Installer is not a Windows PE file: {installer}")

checksum_path = installer.with_name(f"{installer.name}.sha256")
if checksum_path.is_file():
    checksum_text = checksum_path.read_text(encoding="ascii")
    match = re.search(r"\b([0-9a-fA-F]{64})\b", checksum_text)
    if match is None:
        raise SystemExit(f"Invalid installer checksum: {checksum_path}")
    digest = hashlib.sha256(installer.read_bytes()).hexdigest()
    if match.group(1).lower() != digest:
        raise SystemExit(f"Installer checksum mismatch: {checksum_path}")
print(f"smoke: installer ok: {installer}")
PY
}

check_apk
check_dmg
check_installer
