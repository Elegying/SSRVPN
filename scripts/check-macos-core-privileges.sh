#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

runtime=(
  "SSRVPN_MacOS/lib/services/clash_service.dart"
  "SSRVPN_MacOS/lib/services/clash_service_lifecycle.dart"
)
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
  if grep -R -n -F -- "$forbidden" "${runtime[@]}" "$native" >/dev/null; then
    echo "macOS core privilege guard failed: found $forbidden" >&2
    exit 1
  fi
done

python3 - <<'PY'
from pathlib import Path
import re

path = Path("SSRVPN_MacOS/lib/services/clash_service.dart")
lifecycle_path = Path("SSRVPN_MacOS/lib/services/clash_service_lifecycle.dart")
main_source = path.read_text(encoding="utf-8")
lifecycle_source = lifecycle_path.read_text(encoding="utf-8")
source = f"{main_source}\n{lifecycle_source}"
if re.search(r'''['"][2467][0-7]{3}['"]|[ug]\+s''', source):
    raise SystemExit(f"{path}: found a privileged chmod mode")

start = lifecycle_source.index("Future<bool> _startInternal(int startToken)")
stop = lifecycle_source.index("Future<void> stop()", start)
start_body = lifecycle_source[start:stop]
tun_guard = start_body.index("if (settings.enableTun)")
path_guard = start_body.index("if (_corePath.isEmpty")
if tun_guard > path_guard:
    raise SystemExit(f"{path}: TUN must fail before the core startup path")

if "_tunUnavailableMessage" not in start_body:
    raise SystemExit(f"{path}: TUN guard does not publish the safe-mode message")
for token in ("Network Extension", "系统代理模式"):
    if token not in source:
        raise SystemExit(f"{path}: TUN failure message is missing {token}")

install = main_source.index("Future<void> _installCoreAsset")
generic_install = main_source.index("Future<void> _installAsset", install)
install_body = main_source[install:generic_install]
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

if "/usr/bin/pkill" in lifecycle_source or "['-f', _corePath]" in lifecycle_source:
    raise SystemExit(f"{lifecycle_path}: broad pkill core cleanup is forbidden")

app_delegate = Path("SSRVPN_MacOS/macos/Runner/AppDelegate.swift").read_text(
    encoding="utf-8"
)
required_native = (
    "runtimeDirectoryForTermination(proxyStateURL:",
    "terminateOwnedCore(in: runtimeDirectory)",
    "isOwnedCoreCommand(command, corePath: corePath)",
)
missing_native = [token for token in required_native if token not in app_delegate]
if missing_native:
    raise SystemExit(
        "AppDelegate.swift: missing exact owned-core termination guard(s): "
        + ", ".join(missing_native)
    )

print("macOS core privilege guards passed.")
PY

for required in \
  "desktopPlatformLabel != 'MacOS'" \
  'TUN 模式（暂不可用）'; do
  if ! grep -Fq -- "$required" "$dashboard"; then
    echo "macOS TUN UI guard failed: missing $required" >&2
    exit 1
  fi
done
