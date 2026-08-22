# SSRVPN Third-Party Notices

SSRVPN-owned source code is distributed under the repository's MIT License,
included with application packages as `licenses/SSRVPN-MIT.txt`.
The application packages also contain the components below, which remain
subject to their own licenses. A copy of GNU GPL version 3 is distributed next
to this file at `licenses/GPL-3.0.txt`.

The object-code records named below contain the exact SHA-256 values used by
the release. For an SSRVPN release, use the repository tag matching the app
version to obtain the corresponding SSRVPN bridge and build scripts.

## Windows: Microsoft Visual C++ Runtime and D3DCompiler_47

- Components: Microsoft Visual C++ Runtime libraries and
  `D3DCompiler_47.dll`
- Official Microsoft Visual Studio license terms:
  <https://visualstudio.microsoft.com/license-terms/>
- Official Visual Studio redistribution information:
  <https://learn.microsoft.com/en-us/visualstudio/releases/2022/redistribution>
- Official DirectX/Windows SDK redistribution information:
  <https://learn.microsoft.com/en-us/windows/win32/directx-sdk--august-2009->
- Package-specific record: `MICROSOFT_RUNTIME_PROVENANCE.txt`
- Engineering controls: Windows packages accept Visual C++ libraries only
  from Visual Studio Redist candidates, including the toolchain-provided
  `VCToolsRedistDir`; provenance records these candidates with source class
  `VisualStudioRedist`. D3DCompiler is accepted only from an installed
  `WindowsKitsRedist` directory. Packaging requires x64 binaries with a valid
  Microsoft Authenticode signature, records the file version and SHA-256, and
  overwrites any build-output copy with the verified Redist file.

The links above identify the Microsoft redistribution information applied by
the packaging controls. This notice records the engineering provenance and
does not independently grant redistribution rights.

## Windows: MetaCubeX/mihomo v1.19.27

- Component: `MetaCubeX/mihomo`
- Bundled object: `SSRVPN_Windows/assets/mihomo.exe`
- License: GNU GPL version 3 (`GPL-3.0`)
- Exact source: <https://github.com/MetaCubeX/mihomo/tree/v1.19.27>
- Source archive: <https://github.com/MetaCubeX/mihomo/archive/refs/tags/v1.19.27.tar.gz>
- Object-code record: `SSRVPN_Windows/assets/mihomo-source.txt`
- SSRVPN modification notice: SSRVPN extracts and renames the official Windows
  release executable; it does not modify the Mihomo source for this object.

## macOS: MetaCubeX/mihomo v1.19.29

- Component: `MetaCubeX/mihomo`
- Bundled object: `SSRVPN_MacOS/assets/AtlasCore.gz`
- License: GNU GPL version 3 (`GPL-3.0`)
- Exact source: <https://github.com/MetaCubeX/mihomo/tree/v1.19.29>
- Source archive: <https://github.com/MetaCubeX/mihomo/archive/refs/tags/v1.19.29.tar.gz>
- Object-code record: `SSRVPN_MacOS/assets/AtlasCore-source.txt`
- SSRVPN modification notice: SSRVPN renames and decompresses the official
  Apple arm64 release executable at runtime; it does not modify the Mihomo
  source for this object.

## Android: zeyugao/mihomo commit 7031b756

- Component: `zeyugao/mihomo`
- Bundled object: `SSRVPN_Android/android/app/src/main/jniLibs/arm64-v8a/libgojni.so`
- License: GNU GPL version 3 (`GPL-3.0`)
- Exact source commit: <https://github.com/zeyugao/mihomo/tree/7031b7569831677a8d89ad8a8a3347db116ba1a8>
- Source archive: <https://github.com/zeyugao/mihomo/archive/7031b7569831677a8d89ad8a8a3347db116ba1a8.tar.gz>
- SSRVPN bridge source: `SSRVPN_Android/native/bridge/bridge.go`
- Reproducible build recipe: `scripts/build-android-core.sh`
- Object-code record: `SSRVPN_Android/assets/libgojni-source.txt`
- SSRVPN modification notice (2026-08-22): the Android library is a custom
  arm64 shared-library build of the exact source commit with the committed
  SSRVPN Go bridge and the build parameters recorded in the object-code record.

## GeoIP database: MetaCubeX/meta-rules-dat

- Component: `MetaCubeX/meta-rules-dat` generated `geoip.metadb`
- Bundled objects: the three platform `assets/geoip.metadb.gz` files
- License: GNU GPL version 3 (`GPL-3.0`)
- Source and generation repository: <https://github.com/MetaCubeX/meta-rules-dat>
- Exact source commit and immutable source archive record: `docs/GEOIP_SOURCE.txt`
- Exact object and immutable mirror record: `docs/GEOIP_SOURCE.txt`
- SSRVPN modification notice: SSRVPN deterministically compresses and mirrors
  the verified upstream database bytes; it does not change the decompressed
  database content.

## Obtaining source

The exact upstream source links and SSRVPN paths above are the corresponding
source directions for the bundled object code. The complete SSRVPN source for a
published version is available from its matching Git tag at
<https://github.com/Elegying/SSRVPN/tags>. If any listed source becomes
unavailable, report it through <https://github.com/Elegying/SSRVPN/issues> so
the release can be repaired or withdrawn.

These notices describe the project's distribution materials and are not legal
advice.
