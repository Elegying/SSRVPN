#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAC_GUIDE="$ROOT/SSRVPN_MacOS/DMG_README.txt"
WINDOWS_GUIDE="$ROOT/SSRVPN_Windows/PORTABLE_README.txt"

expected_macos=$'1、双击 DMG 文件打开后，拖动 SSRVPN 图标到 Applications 里。\n2、去“应用程序”里找到软件，或者搜索 SSRVPN，然后右键图标并选择“打开”。\n3、打开软件后，导入订阅链接或者节点代码。\n4、点击连接按钮即可。'
expected_windows=$'1、下载完 ZIP 后，使用解压软件解压出来。\n2、双击 ssrvpn_windows.exe 打开软件。\n3、粘贴你的节点代码或者订阅链接。\n4、点击连接按钮即可。'

if [[ ! -f "$MAC_GUIDE" ]]; then
  echo "package guide check failed: missing $MAC_GUIDE" >&2
  exit 1
fi

actual_macos="$(sed -n '3,6p' "$MAC_GUIDE")"
if [[ "$actual_macos" != "$expected_macos" ]]; then
  echo "package guide check failed: macOS tutorial does not match" >&2
  exit 1
fi

actual_windows="$(
  awk '
    /^  使用方法$/ { in_usage = 1; next }
    in_usage && /^[1-4]、/ {
      print
      count++
      if (count == 4) exit
    }
  ' "$WINDOWS_GUIDE"
)"
if [[ "$actual_windows" != "$expected_windows" ]]; then
  echo "package guide check failed: Windows tutorial does not match" >&2
  exit 1
fi

echo "Package guide checks passed."
