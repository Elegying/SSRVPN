# Core Binary Assets

SSRVPN bundles Mihomo core binaries through Git LFS. Do not commit these files
as plain Git blobs, and do not replace them without recording source, version,
and hashes.

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
- Current core source: MetaCubeX/mihomo `v1.19.27`
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

The stored gzip may be recompressed during local packaging; compare the
decompressed executable SHA256 when verifying equivalence with an official
GitHub release asset.

## Verification

```bash
git lfs pull
scripts/verify-core-assets.sh
```

`scripts/verify-core-assets.sh` checks Git LFS pointer leakage, fixed SHA256
hashes, macOS decompressed executable equivalence, and bundled geo databases.
Geo database source and hashes are recorded in `docs/GEOIP_SOURCE.txt`; refresh
them before release with `python3 scripts/sync-geoip-metadb.py`.
The same check runs in CI and before each platform release build.

Windows executable verification is also performed by
`SSRVPN_Windows/tool/package_windows.ps1` when producing the portable ZIP.
