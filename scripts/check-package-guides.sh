#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_GUIDE="$ROOT/SSRVPN_MacOS/DMG_README.txt"
WINDOWS_GUIDE="$ROOT/SSRVPN_Windows/USER_GUIDE.md"

expected_macos=$'1、双击 DMG 文件打开后，拖动 SSRVPN 图标到 Applications 里。\n2、去“应用程序”里找到软件，或者搜索 SSRVPN，然后右键图标并选择“打开”。\n3、打开软件后，导入订阅链接或者节点代码。\n4、点击连接按钮即可。'

if [[ ! -f "$MAC_GUIDE" ]]; then
  echo "package guide check failed: missing $MAC_GUIDE" >&2
  exit 1
fi

actual_macos="$(sed -n '3,6p' "$MAC_GUIDE")"
if [[ "$actual_macos" != "$expected_macos" ]]; then
  echo "package guide check failed: macOS tutorial does not match" >&2
  exit 1
fi

if [[ ! -f "$WINDOWS_GUIDE" ]] || \
  ! grep -Fq '`SSRVPN_Setup.exe`' "$WINDOWS_GUIDE"; then
  echo "package guide check failed: Windows installer guide is missing" >&2
  exit 1
fi

if grep -Fq '`SSRVPN.zip`' "$WINDOWS_GUIDE"; then
  echo "package guide check failed: Windows guide still advertises a portable package" >&2
  exit 1
fi

if ! grep -Fq 'run-command-with-timeout.py' \
  "$ROOT/SSRVPN_MacOS/tool/package_macos.sh"; then
  echo "package guide check failed: Finder layout must have a hard timeout" >&2
  exit 1
fi

echo "Package guide checks passed."
