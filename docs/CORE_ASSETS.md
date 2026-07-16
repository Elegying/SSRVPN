# Core Binary Assets

SSRVPN downloads its large native assets from immutable GitHub Release URLs.
The files are generated locally, ignored by Git, and accepted only after their
container and extracted SHA256 values match the committed source records.

## Windows

- Bundled file: `SSRVPN_Windows/assets/mihomo.exe`
- Geo database: `SSRVPN_Windows/assets/geoip.metadb.gz`
- Source record: `SSRVPN_Windows/assets/mihomo-source.txt`
- Geo source record: `docs/GEOIP_SOURCE.txt`
- Current source: MetaCubeX/mihomo `v1.19.27`
- Required asset family: `mihomo-windows-amd64-v1-go120-*.zip`

Use the `v1-go120` Windows build for broad compatibility with older Windows
installations and older x86-64 CPUs. After downloading, extract the executable,
rename it to `mihomo.exe`, place it in `SSRVPN_Windows/assets/`, and update
`mihomo-source.txt` with the official asset URL and SHA256 values.

## Android

- Bundled file: `SSRVPN_Android/android/app/src/main/jniLibs/arm64-v8a/libgojni.so`
- Geo database: `SSRVPN_Android/assets/geoip.metadb.gz`
- Source record: `SSRVPN_Android/assets/libgojni-source.txt`
- Bootstrap container: the signed SSRVPN `v2.4.5` APK
- Geo source record: `docs/GEOIP_SOURCE.txt`

The Android native library is loaded by the VPN service, so it must be verified
before CI tests and release packaging.

## macOS

- Bundled file: `SSRVPN_MacOS/assets/AtlasCore.gz`
- Geo database: `SSRVPN_MacOS/assets/geoip.metadb.gz`
- Source record: `SSRVPN_MacOS/assets/AtlasCore-source.txt`
- Geo source record: `docs/GEOIP_SOURCE.txt`
- Current source: MetaCubeX/mihomo `v1.19.27`
- Required asset family: `mihomo-darwin-arm64-*.gz`

The stored gzip is the official release asset. Verification checks both its
compressed SHA256 and the decompressed executable SHA256.

## Verification

```bash
make assets
scripts/verify-core-assets.sh
```

`scripts/bootstrap-core-assets.sh` uses only allowlisted HTTPS GitHub URLs,
downloads into a temporary directory, verifies SHA256 before extraction or
installation, and atomically replaces stale local assets. The normal bootstrap
GeoIP snapshot comes from the immutable `v2.4.5` APK so old commits remain
reproducible. Release builds refresh it with
`python3 scripts/sync-geoip-metadb.py` before packaging.

`scripts/verify-core-assets.sh` checks fixed SHA256 hashes, macOS decompressed
executable equivalence, and bundled GeoIP databases. The same checks run in CI
and before each platform release build. CI prepares the verified assets once
and shares them with platform jobs through GitHub Actions artifacts.

Windows executable verification is also performed by
`SSRVPN_Windows/tool/package_windows.ps1` when preparing the installer payload.

## Runtime rule providers

Generated Mihomo configurations use the MetaCubeX `geoip/cn.mrs` and
`geosite/cn.mrs` rule providers pinned to commit
`200e6a86736cfab29aae7b07dc266e59f13bc13d`; they do not follow the mutable
`meta` branch. The generated rules also keep built-in `DOMAIN-SUFFIX,cn` and
`GEOIP,CN` fallbacks, so a temporary provider download failure does not remove
the baseline China-direct routing behavior. Updating the pinned commit requires
reviewing both files and updating the configuration regression test in the same
change.
