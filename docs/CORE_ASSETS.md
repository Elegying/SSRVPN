# Core Binary Assets

SSRVPN downloads its large native assets from immutable GitHub Release URLs.
The files are generated locally, ignored by Git, and accepted only after their
container and extracted SHA256 values match the committed source records.
The bundled binaries and GeoIP database are not relicensed by SSRVPN. Exact
license, corresponding-source and modification directions are maintained in
[`third_party/THIRD_PARTY_NOTICES.md`](../third_party/THIRD_PARTY_NOTICES.md),
and every release package must include that notice plus the complete GPL and
SSRVPN MIT texts.

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
- Source bridge: `SSRVPN_Android/native/bridge/bridge.go`
- Build recipe: `scripts/build-android-core.sh`
- Geo source record: `docs/GEOIP_SOURCE.txt`

The Android native library is loaded by the VPN service, so it must be verified
before CI tests and release packaging.

The Android core is source-rebuildable from the reviewed Mihomo commit and tree,
the committed bridge, Go `1.25.11`, the pinned `x/mobile` revision, and Android
NDK r28c. The published core is mirrored as a content-addressed asset in the
`core-assets-v1` support release. Verification checks its SHA256, embedded Go
build contract, six JNI exports, AArch64 target, and every ELF `LOAD` segment's
16 KiB alignment before tests or packaging can proceed.

## macOS

- Bundled file: `SSRVPN_MacOS/assets/AtlasCore.gz`
- Geo database: `SSRVPN_MacOS/assets/geoip.metadb.gz`
- Source record: `SSRVPN_MacOS/assets/AtlasCore-source.txt`
- Geo source record: `docs/GEOIP_SOURCE.txt`
- Current source: MetaCubeX/mihomo `v1.19.29`
- Required asset family: `mihomo-darwin-arm64-*.gz`

The stored gzip is the official release asset. Verification checks both its
compressed SHA256 and the decompressed executable SHA256.

## Verification

```bash
make assets
scripts/verify-core-assets.sh
python3 -m unittest scripts/test_third_party_licenses.py
```

`scripts/bootstrap-core-assets.sh` uses only allowlisted HTTPS GitHub URLs,
downloads into a temporary directory, verifies SHA256 before extraction or
installation, and atomically replaces stale local assets. GeoIP bootstrap reads
only the content-addressed deterministic gzip in SSRVPN's `core-assets-v1`
support prerelease. The support release is published but marked prerelease and
non-latest so it cannot replace the current application release. Its
`core-assets-v1` tag is covered by the repository's active release-tag ruleset,
which rejects updates and deletion just like application `v*` tags.
`GEOIP_SOURCE.txt` pins that asset's exact name and URL, its
gzip SHA256, and the decompressed upstream SHA256. The bootstrap accepts only
the `Elegying/SSRVPN/releases/download/core-assets-v1/` path and verifies both
hashes before installing the same bytes for all three platforms. It never needs
the upstream project's mutable Release during a normal CI or release build.

The `Prepare Release` workflow is the normal release entrypoint. It bootstraps
and verifies the repository-pinned assets, validates the exact `main`, and then
creates the application tag and starts `release.yml`. It never queries upstream
GeoIP freshness, changes `GEOIP_SOURCE.txt`, uploads a mirror asset, or creates a
GeoIP PR. `Maintenance > geoip-refresh` is the only update entrypoint and is run
only after an explicit maintainer decision; it has no schedule trigger.
An expired Asset ID in the previous upstream provenance therefore cannot block
the manual refresh. The trust boundary disables redirects on authenticated API
calls; mirror readback permits only GitHub's HTTPS download/CDN hosts and strips
credentials from redirects. Concurrent same-name uploads are re-listed and
accepted only when the public gzip/raw hashes match.

For a new release, `release.yml` bootstraps and verifies the reviewed pinned
asset without contacting upstream to judge whether it is current. A fixed snapshot
may be released repeatedly until the maintainer explicitly requests an update.
Recovery retries backed by an exact-tag Release still require IDs, upload states,
digests, commit, and provenance to validate. Hidden drafts are located through a
read-only paginated API fallback and provenance is fetched by validated asset ID;
missing, duplicate, incomplete, or unreachable releases fail closed. The validated
Release ID and a canonical hash of every asset identity are passed to the publish
job and verified again. If that Release disappears or changes while builds run,
publishing fails instead of deleting the draft or creating a replacement. Retry
finalization, public-state polling, and post-publication validation use that numeric
Release ID; only the expected draft-to-public transition is excluded from the
immutable asset identity. The retry identity is checked after OSS promotion but
before the numeric-ID PATCH, and again after the public-state poll before the OSS
recovery backup is discarded. These trust boundaries are recorded in
[ADR-005](decisions/005-content-addressed-geoip-mirror.md), and the manual-only
update policy is recorded in
[ADR-014](decisions/014-manual-only-geoip-updates.md).

`scripts/verify-core-assets.sh` checks fixed SHA256 hashes, macOS decompressed
executable equivalence, Android embedded Go build properties and 16 KiB ELF/JNI
compatibility, and bundled GeoIP databases. The same checks run in CI and before each platform release build. CI
prepares the verified assets once and shares them with platform jobs through
GitHub Actions artifacts.

Windows executable verification is also performed by
`SSRVPN_Windows/tool/package_windows.ps1` when preparing the installer payload.

## Runtime rule providers

Generated Mihomo configurations use the MetaCubeX `geosite/gfw.mrs` and
`geosite/cn.mrs` rule providers pinned to the same commit
`200e6a86736cfab29aae7b07dc266e59f13bc13d`; they do not follow the mutable
`main`, `master`, `latest`, or `release` references. Both providers use the
`PROXY` group for downloads, fixed cache paths under `providers/`, and the same
one-shot startup refresh. Mihomo retains an existing usable cache when a refresh
fails; SSRVPN never deletes provider files in the failure path. The generated
rules keep local/private, `DOMAIN-SUFFIX,cn`, and `GEOIP,CN` direct fallbacks,
then finish with `MATCH,DIRECT`. Updating the pinned commit requires reviewing
both files and updating the configuration regression tests in the same change.
