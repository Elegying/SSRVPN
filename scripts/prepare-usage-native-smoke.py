#!/usr/bin/env python3
"""Create a disposable native host; never load SSRVPN settings or VPN services."""
import base64
import json
import re
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    repository = Path(__file__).resolve().parents[1]
    host = Path(tempfile.mkdtemp(prefix="ssrvpn-usage-native-"))
    subprocess.run([
        "flutter", "create", "--no-pub", "--platforms=android,macos,windows",
        "--org=test.ssrvpn", "--project-name=usage_smoke", str(host),
    ], check=True)
    pubspec = host / "pubspec.yaml"
    shared = (repository / "packages/ssrvpn_shared").as_posix().replace("'", "''")
    pubspec.write_text(pubspec.read_text().replace(
        "dependencies:", f"dependencies:\n  ssrvpn_shared:\n    path: '{shared}'", 1))
    shutil.copyfile(repository / "pubspec.lock", host / "pubspec.lock")
    shutil.copyfile(repository / "packages/ssrvpn_shared/tool/account_usage_native_smoke.dart",
                    host / "lib/main.dart")
    for name in ("DebugProfile.entitlements", "Release.entitlements"):
        path = host / "macos/Runner" / name
        text = path.read_text()
        if "com.apple.security.network.client" not in text:
            text = text.replace("<dict>", "<dict>\n<key>com.apple.security.network.client</key><true/>", 1)
        if "com.apple.security.network.server" not in text:
            text = text.replace("<dict>", "<dict>\n<key>com.apple.security.network.server</key><true/>", 1)
        path.write_text(text)
    policy = (repository / "packages/ssrvpn_shared/lib/utils/desktop_window_state_store.dart").read_text()
    minimum = re.search(r"minimumSize = Size\((\d+), (\d+)\)", policy)
    if minimum is None:
        raise SystemExit("Cannot resolve the existing desktop minimum size")
    width, height = minimum.groups()
    mac = host / "macos/Runner/MainFlutterWindow.swift"
    mac.write_text(mac.read_text().replace(
        "    let flutterViewController", f"    minSize = NSSize(width: {width}, height: {height})\n    let flutterViewController", 1))
    windows = host / "windows/runner/win32_window.cpp"
    windows.write_text(windows.read_text().replace(
        "    case WM_DESTROY:", f"""    case WM_GETMINMAXINFO: {{
      auto* bounds = reinterpret_cast<MINMAXINFO*>(lparam);
      const auto monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
      const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
      bounds->ptMinTrackSize.x = Scale({width}, scale);
      bounds->ptMinTrackSize.y = Scale({height}, scale);
      return 0;
    }}
    case WM_DESTROY:""", 1))
    cert, key = host / "test-cert.pem", host / "test-key.pem"
    result = subprocess.run([
        "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
        "-keyout", str(key), "-out", str(cert), "-days", "1", "-subj", "/CN=localhost",
        "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
        "-addext", "basicConstraints=critical,CA:TRUE",
        "-addext", "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign",
        "-addext", "extendedKeyUsage=serverAuth",
    ], capture_output=True)
    if result.returncode:
        raise SystemExit("Local test certificate generation failed; requires openssl with -addext")
    key.chmod(0o600)
    defines = host / "test-defines.json"
    defines.write_text(json.dumps({
        "SSRVPN_UAT_CERT": base64.b64encode(cert.read_bytes()).decode("ascii"),
        "SSRVPN_UAT_KEY": base64.b64encode(key.read_bytes()).decode("ascii"),
    }))
    defines.chmod(0o600)
    subprocess.run(["flutter", "pub", "get"], cwd=host, check=True)
    print(f"Disposable host: {host}")
    print("Run separately on each available native platform:")
    print("flutter run -d <macos|windows|android-device-id> --dart-define-from-file=test-defines.json")
    print("The host reports USAGE_NATIVE_PASS after eight steps and exits. Delete the temporary host after validation.")


if __name__ == "__main__":
    main()
