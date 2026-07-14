#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

runtime=(
  "SSRVPN_MacOS/lib/services/clash_service.dart"
  "SSRVPN_MacOS/lib/services/clash_service_lifecycle.dart"
  "SSRVPN_MacOS/lib/services/macos_tun_session.dart"
)
native="SSRVPN_MacOS/macos/Runner"
runner="SSRVPN_MacOS/assets/macos_tun_runner.sh"
connection_options="packages/ssrvpn_shared/lib/desktop_ui/widgets/desktop_home_connection_options_part.dart"

for forbidden in \
  '_grantRootPrivilege' \
  '_coreHasRootPrivilege' \
  '/usr/sbin/chown' \
  'root:wheel' \
  'chmod u+s'; do
  if grep -R -n -F -- "$forbidden" "${runtime[@]}" "$native" "$runner" >/dev/null; then
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

for token in ("MacosTunSession", "_startTunCore", "tunSession.start()"):
    if token not in source:
        raise SystemExit(f"{path}: missing authorized TUN session boundary: {token}")
if "_tunUnavailableMessage" in source:
    raise SystemExit(f"{path}: obsolete TUN unavailable guard remains")

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
  'with administrator privileges' \
  '/usr/bin/osascript' \
  'macos_tun_runner.sh' \
  '.tun-session-request'; do
  if ! grep -R -Fq -- "$required" "${runtime[@]}" "$native" "$runner"; then
    echo "macOS TUN authorization guard failed: missing $required" >&2
    exit 1
  fi
done

if grep -Fq '/usr/bin/nohup' \
    SSRVPN_MacOS/lib/services/macos_tun_session.dart; then
  echo "macOS TUN authorization guard failed: root runner must stay attached" >&2
  exit 1
fi

for required in \
  '[[ ${EUID:-$(id -u)} -eq 0 ]]' \
  'Mihomo core digest mismatch' \
  'the requesting app is not owned by the console user' \
  '/var/run/ssrvpn-tun-$user_id' \
  'kill -0 "$app_pid"' \
  '/var/run/ssrvpn-tun-status-$app_pid' \
  'write_status "error:tun"' \
  'for _ in {1..24}'; do
  if ! grep -Fq -- "$required" "$runner"; then
    echo "macOS TUN runner guard failed: missing $required" >&2
    exit 1
  fi
done

python3 - <<'PY'
from hashlib import sha256
from pathlib import Path
import re

session_path = Path("SSRVPN_MacOS/lib/services/macos_tun_session.dart")
session = session_path.read_text(encoding="utf-8")
assets = {
    "_runnerSha256": Path("SSRVPN_MacOS/assets/macos_tun_runner.sh"),
    "_coreArchiveSha256": Path("SSRVPN_MacOS/assets/AtlasCore.gz"),
    "_coreManifestSha256": Path("SSRVPN_MacOS/assets/AtlasCore-source.txt"),
}
for constant, path in assets.items():
    match = re.search(
        rf"{constant}\s*=\s*\n?\s*'([0-9a-f]{{64}})'",
        session,
    )
    if match is None:
        raise SystemExit(f"{session_path}: missing pinned digest {constant}")
    actual = sha256(path.read_bytes()).hexdigest()
    if match.group(1) != actual:
        raise SystemExit(
            f"{session_path}: stale {constant}; expected digest for {path} is {actual}"
        )

for token in (
    "/var/run/ssrvpn-tun-launch-$app_pid",
    "check_hash \"$stage/macos_tun_runner.sh\"",
    "check_hash \"$stage/AtlasCore.gz\"",
    "check_hash \"$stage/AtlasCore-source.txt\"",
    "check_hash \"$stage/config.yaml\"",
):
    if token not in session:
        raise SystemExit(f"{session_path}: missing root-owned staging guard: {token}")

print("macOS TUN staged resource digests passed.")
PY

for required in \
  'TUN 模式（连接时需管理员授权）'; do
  if ! grep -Fq -- "$required" "$connection_options"; then
    echo "macOS TUN UI guard failed: missing $required" >&2
    exit 1
  fi
done
