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
  local mount_dir
  mount_dir="$(mktemp -d)"
  cleanup() {
    if mount | grep -qF "$mount_dir"; then
      hdiutil detach "$mount_dir" -force >/dev/null 2>&1 || true
    fi
    rm -rf "$mount_dir"
  }
  trap cleanup RETURN
  hdiutil attach -readonly -nobrowse -mountpoint "$mount_dir" "$dmg" >/dev/null
  test -d "$mount_dir/SSRVPN.app"
  test -L "$mount_dir/Applications"
  echo "smoke: DMG ok: $dmg"
}

check_zip() {
  local zip=""
  for candidate in SSRVPN_Windows/SSRVPN.zip SSRVPN_Windows/build/SSRVPN.zip; do
    if [[ -f "$candidate" ]]; then
      zip="$candidate"
      break
    fi
  done
  [[ -n "$zip" ]] || { missing "Windows ZIP"; return; }
  python3 - "$zip" <<'PY'
from pathlib import PurePosixPath
import sys
import zipfile

zip_path = sys.argv[1]
with zipfile.ZipFile(zip_path) as zf:
    names = [PurePosixPath(name) for name in zf.namelist() if not name.endswith("/")]

roots = {path.parts[0] for path in names if path.parts}
if "SSRVPN_Windows_Release" not in roots:
    raise SystemExit("ZIP missing SSRVPN_Windows_Release root")

root_files = [
    path.parts[1]
    for path in names
    if len(path.parts) == 2 and path.parts[0] == "SSRVPN_Windows_Release"
]
root_exes = [name for name in root_files if name.lower().endswith(".exe")]
if root_exes != ["ssrvpn_windows.exe"]:
    raise SystemExit(f"ZIP root must contain one user-facing exe: {root_exes}")

required = {
    "SSRVPN_Windows_Release/bin/ssrvpn_windows_app.exe",
    "SSRVPN_Windows_Release/bin/mihomo.exe",
    "SSRVPN_Windows_Release/bin/data/flutter_assets/assets/geoip.metadb.gz",
}
all_names = {path.as_posix() for path in names}
missing = sorted(required - all_names)
if missing:
    raise SystemExit(f"ZIP missing required files: {missing}")
print(f"smoke: ZIP ok: {zip_path}")
PY
}

check_apk
check_dmg
check_zip
