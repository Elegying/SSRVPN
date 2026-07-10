#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

runtime="SSRVPN_MacOS/lib/services/clash_service.dart"
native="SSRVPN_MacOS/macos/Runner"
dashboard="packages/ssrvpn_shared/lib/desktop_ui/widgets/desktop_home_dashboard_part.dart"

for forbidden in \
  '_grantRootPrivilege' \
  '_coreHasRootPrivilege' \
  'with administrator privileges' \
  '/usr/sbin/chown' \
  'root:wheel' \
  'chmod u+s' \
  '/usr/bin/osascript'; do
  if rg -n --fixed-strings "$forbidden" "$runtime" "$native" >/dev/null; then
    echo "macOS core privilege guard failed: found $forbidden" >&2
    exit 1
  fi
done

python3 - <<'PY'
from pathlib import Path
import re

path = Path("SSRVPN_MacOS/lib/services/clash_service.dart")
source = path.read_text(encoding="utf-8")
if re.search(r'''['"][2467][0-7]{3}['"]|[ug]\+s''', source):
    raise SystemExit(f"{path}: found a privileged chmod mode")

start = source.index("Future<bool> _startInternal()")
stop = source.index("Future<void> stop()", start)
start_body = source[start:stop]
tun_guard = start_body.index("if (settings.enableTun)")
path_guard = start_body.index("if (_corePath.isEmpty")
if tun_guard > path_guard:
    raise SystemExit(f"{path}: TUN must fail before the core startup path")

if "_tunUnavailableMessage" not in start_body:
    raise SystemExit(f"{path}: TUN guard does not publish the safe-mode message")
for token in ("Network Extension", "系统代理模式"):
    if token not in source:
        raise SystemExit(f"{path}: TUN failure message is missing {token}")

install = source.index("Future<void> _installCoreAsset")
generic_install = source.index("Future<void> _installAsset", install)
install_body = source[install:generic_install]
remove = install_body.index("_removeUntrustedPathEntry(destPath)")
decompress = install_body.index("Isolate.run")
if remove > decompress:
    raise SystemExit(f"{path}: legacy core is not unlinked before decompression")

required = (
    "await _ensureRealDirectory(configDir)",
    "FileSystemEntity.type(path, followLinks: false)",
    "temp.create(exclusive: true)",
    "_privilegedModeBits",
    "_fileSha256(corePath)",
    "_verifyCoreForExecution()",
)
missing = [token for token in required if token not in source]
if missing:
    raise SystemExit(
        f"{path}: missing core file safety guard(s): {', '.join(missing)}"
    )

if source.count("await _verifyCoreForExecution();") < 3:
    raise SystemExit(f"{path}: not every core execution path is guarded")

print("macOS core privilege guards passed.")
PY

for required in \
  "desktopPlatformLabel != 'MacOS'" \
  'TUN 模式（macOS 暂不可用）'; do
  if ! rg -q --fixed-strings "$required" "$dashboard"; then
    echo "macOS TUN UI guard failed: missing $required" >&2
    exit 1
  fi
done
