# Core Binary Assets

SSRVPN bundles Mihomo core binaries through Git LFS. Do not commit these files
as plain Git blobs, and do not replace them without recording source, version,
and hashes.

## Windows

- Bundled file: `SSRVPN_Windows/assets/mihomo.exe`
- Source record: `SSRVPN_Windows/assets/mihomo-source.txt`
- Current source: MetaCubeX/mihomo `v1.19.27`
- Required asset family: `mihomo-windows-amd64-v1-go120-*.zip`

Use the `v1-go120` Windows build for broad compatibility with older Windows
installations and older x86-64 CPUs. After downloading, extract the executable,
rename it to `mihomo.exe`, place it in `SSRVPN_Windows/assets/`, and update
`mihomo-source.txt` with the official asset URL and SHA256 values.

## macOS

- Bundled file: `SSRVPN_MacOS/assets/AtlasCore.gz`
- Source record: `SSRVPN_MacOS/assets/AtlasCore-source.txt`
- Current source: MetaCubeX/mihomo `v1.19.27`
- Required asset family: `mihomo-darwin-arm64-*.gz`

The stored gzip may be recompressed during local packaging; compare the
decompressed executable SHA256 when verifying equivalence with an official
GitHub release asset.

## Verification

```bash
git lfs pull
shasum -a 256 SSRVPN_Windows/assets/mihomo.exe
shasum -a 256 SSRVPN_MacOS/assets/AtlasCore.gz

gzip -cd SSRVPN_MacOS/assets/AtlasCore.gz > /tmp/AtlasCore
chmod +x /tmp/AtlasCore
/tmp/AtlasCore -v
```

Windows executable verification is performed by `SSRVPN_Windows/tool/package_windows.ps1`
when producing the portable ZIP.
