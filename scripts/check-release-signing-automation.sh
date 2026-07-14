#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

python3 - <<'PY'
from pathlib import Path

workflow = Path(".github/workflows/release.yml").read_text(encoding="utf-8")
mac_package = Path("SSRVPN_MacOS/tool/package_macos.sh").read_text(encoding="utf-8")
windows_package = Path("SSRVPN_Windows/tool/package_windows.ps1").read_text(
    encoding="utf-8-sig"
)
windows_installer = Path("SSRVPN_Windows/tool/build_installer.ps1").read_text(
    encoding="utf-8-sig"
)
windows_signer = Path("scripts/sign_windows_artifacts.ps1").read_text(
    encoding="utf-8-sig"
)

for token in (
    "ENABLE_MACOS_SIGNING",
    "validate_release_signing.py macos",
    "notarytool submit",
    "stapler staple",
    "ENABLE_WINDOWS_SIGNING",
    "validate_release_signing.py windows",
    "WINDOWS_SIGNING_CERTIFICATE_PATH",
):
    if token not in workflow:
        raise SystemExit(f"release workflow is missing optional signing token: {token}")

for token in (
    "MACOS_SIGNING_ENABLED",
    "--options runtime --timestamp",
    "--sign \"$SIGNING_IDENTITY\"",
):
    if token not in mac_package:
        raise SystemExit(f"macOS package script is missing signing token: {token}")
if mac_package.index("Applying Developer ID signature") > mac_package.index(
    "hdiutil create"
):
    raise SystemExit("macOS app must be signed before DMG creation")
if mac_package.index("Signing DMG") > mac_package.index("SHA256="):
    raise SystemExit("macOS DMG must be signed before checksumming")

signing_script_name = "sign_windows_artifacts.ps1"
if signing_script_name not in windows_package:
    raise SystemExit("Windows portable package does not invoke Authenticode signing")
if windows_package.index(signing_script_name) > windows_package.index("$hashLines"):
    raise SystemExit("Windows portable binaries must be signed before internal hashes")
if signing_script_name not in windows_installer:
    raise SystemExit("Windows installer does not invoke Authenticode signing")
if windows_installer.index(signing_script_name) > windows_installer.index("Get-FileHash"):
    raise SystemExit("Windows installer must be signed before checksumming")

for token in (
    "signtool.exe",
    "WINDOWS_SIGNING_CERTIFICATE_PATH",
    "WINDOWS_CERTIFICATE_PASSWORD",
    "https://timestamp.digicert.com",
    "verify /pa /all",
):
    if token not in windows_signer:
        raise SystemExit(f"Windows signing helper is missing token: {token}")

print("Optional desktop release-signing automation passed.")
PY
