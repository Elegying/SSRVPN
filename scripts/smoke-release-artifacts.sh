#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

allow_missing=0
require_checksums=0
for argument in "$@"; do
  case "$argument" in
    --allow-missing) allow_missing=1 ;;
    --require-checksums) require_checksums=1 ;;
    *)
      echo "smoke: unknown argument: $argument" >&2
      exit 2
      ;;
  esac
done

missing() {
  if [[ "$allow_missing" -eq 1 ]]; then
    echo "smoke: skip $1, artifact not found"
    return 0
  fi
  echo "smoke: missing $1" >&2
  return 1
}

verify_checksum() {
  local artifact=$1
  local checksum_path="${artifact}.sha256"
  if [[ ! -f "$checksum_path" ]]; then
    if [[ "$require_checksums" -eq 1 ]]; then
      echo "smoke: missing checksum $checksum_path" >&2
      return 1
    fi
    echo "smoke: checksum not present for $artifact"
    return 0
  fi
  python3 - "$artifact" "$checksum_path" <<'PY'
from pathlib import Path
import hashlib
import re
import sys

artifact = Path(sys.argv[1])
checksum_path = Path(sys.argv[2])
checksum_text = checksum_path.read_text(encoding="ascii")
match = re.search(r"\b([0-9a-fA-F]{64})\b", checksum_text)
if match is None:
    raise SystemExit(f"Invalid checksum: {checksum_path}")
hasher = hashlib.sha256()
with artifact.open("rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        hasher.update(chunk)
digest = hasher.hexdigest()
if match.group(1).lower() != digest:
    raise SystemExit(f"Checksum mismatch: {checksum_path}")
print(f"smoke: checksum ok: {checksum_path}")
PY
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
    for required in (
        "assets/THIRD_PARTY_NOTICES.md",
        "assets/licenses/GPL-3.0.txt",
        "assets/licenses/SSRVPN-MIT.txt",
    ):
        if required not in names:
            raise SystemExit(f"APK missing third-party license material: {required}")
print(f"smoke: APK ok: {apk}")
PY
  verify_checksum "$apk"
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
  verify_checksum "$dmg"
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
  test -f "$MOUNT_DIR/SSRVPN.app/Contents/Resources/third_party/THIRD_PARTY_NOTICES.md"
  test -f "$MOUNT_DIR/SSRVPN.app/Contents/Resources/third_party/licenses/GPL-3.0.txt"
  test -f "$MOUNT_DIR/SSRVPN.app/Contents/Resources/third_party/licenses/SSRVPN-MIT.txt"
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
  local packaged_provenance="SSRVPN_Windows/SSRVPN_Windows_Release/third_party/MICROSOFT_RUNTIME_PROVENANCE.txt"
  if [[ -d "SSRVPN_Windows/SSRVPN_Windows_Release" ]]; then
    test -s "$packaged_provenance" || {
      echo "smoke: Windows package missing Microsoft runtime provenance" >&2
      return 1
    }
  fi
  python3 - "$installer" <<'PY'
from pathlib import Path
import sys

installer = Path(sys.argv[1])
if installer.stat().st_size <= 1024 * 1024:
    raise SystemExit(f"Installer too small: {installer}")
with installer.open("rb") as stream:
    if stream.read(2) != b"MZ":
        raise SystemExit(f"Installer is not a Windows PE file: {installer}")

print(f"smoke: installer ok: {installer}")
PY
  verify_checksum "$installer"
}

check_apk
check_dmg
check_installer
