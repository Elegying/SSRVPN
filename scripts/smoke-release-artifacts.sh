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
  test -f "$mount_dir/使用教程.txt"
  grep -Fqx '1、双击 DMG 文件打开后，拖动 SSRVPN 图标到 Applications 里。' \
    "$mount_dir/使用教程.txt"
  grep -Fqx '4、点击连接按钮即可。' "$mount_dir/使用教程.txt"
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
from pathlib import Path, PurePosixPath
import re
import sys
import zipfile

zip_path = sys.argv[1]
with zipfile.ZipFile(zip_path) as zf:
    raw_names = zf.namelist()
names = [
    PurePosixPath(name.replace("\\", "/"))
    for name in raw_names
    if not name.endswith(("/", "\\"))
]

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

runtime_dlls = [
    "concrt140.dll",
    "msvcp140.dll",
    "msvcp140_1.dll",
    "msvcp140_2.dll",
    "msvcp140_atomic_wait.dll",
    "msvcp140_codecvt_ids.dll",
    "vcruntime140.dll",
    "vcruntime140_1.dll",
]
required = {
    "SSRVPN_Windows_Release/bin/ssrvpn_windows_app.exe",
    "SSRVPN_Windows_Release/bin/mihomo.exe",
    "SSRVPN_Windows_Release/bin/data/flutter_assets/assets/geoip.metadb.gz",
    "SSRVPN_Windows_Release/使用教程.txt",
}
for dll in runtime_dlls:
    required.add(f"SSRVPN_Windows_Release/{dll}")
    required.add(f"SSRVPN_Windows_Release/bin/{dll}")
all_names = {path.as_posix() for path in names}
missing = sorted(required - all_names)
if missing:
    raise SystemExit(f"ZIP missing required files: {missing}")

guide_path = "SSRVPN_Windows_Release/使用教程.txt"
guide_entry = next(
    name for name in raw_names if name.replace("\\", "/") == guide_path
)
with zipfile.ZipFile(zip_path) as zf:
    guide = zf.read(guide_entry).decode("utf-8-sig")
first_line = guide.splitlines()[0] if guide.splitlines() else ""
pubspec = Path("SSRVPN_Windows/pubspec.yaml").read_text(encoding="utf-8")
version_match = re.search(r"^version:\s+([^+\s]+)", pubspec, re.MULTILINE)
if version_match is None:
    raise SystemExit("Windows pubspec version is missing")
expected_title = f"SSRVPN Windows 便携版 v{version_match.group(1)}"
if first_line != expected_title:
    raise SystemExit(f"ZIP tutorial title is invalid: {first_line!r}")
expected_steps = [
    "1、下载完 ZIP 后，使用解压软件解压出来。",
    "2、双击 ssrvpn_windows.exe 打开软件。",
    "3、粘贴你的节点代码或者订阅链接。",
    "4、点击连接按钮即可。",
]
actual_steps = [
    line
    for line in guide.splitlines()
    if line[:2] in {"1、", "2、", "3、", "4、"}
]
if actual_steps != expected_steps:
    raise SystemExit(f"ZIP tutorial steps do not match: {actual_steps}")
print(f"smoke: ZIP ok: {zip_path}")
PY
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
check_zip
check_installer
