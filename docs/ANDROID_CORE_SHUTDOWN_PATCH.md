# Android embedded core shutdown patch

## Scope

The Android app pins the ARM64 `libgojni.so` extracted from SSRVPN v2.4.5. Its
local Go bridge closes only the TUN listener in `Bridge.stop()`. The mixed and
SOCKS listeners remain open, so the Android fail-closed cleanup has to terminate
the whole app process after every normal disconnect.

## Reproducible patch

`scripts/patch-android-core-shutdown.py` accepts only the recorded upstream
SHA-256 and rewrites one reviewed ARM64 call site in `Bridge.stop()`. After the
TUN listener closes, the hook calls Mihomo's existing `ReCreateMixed(0, nil)`,
`ReCreateSocks(0, nil)`, and `executor.Shutdown()` functions. A final SHA-256 and
the exact instruction sequence are checked before the file is installed.

The external controller is intentionally not used as the shutdown signal. It is
managed by a separate embedded HTTP server and is closed and recreated when the
next configuration starts. Android verifies release of the configured mixed and
SOCKS data-plane ports before accepting a clean disconnect.

## Verification

Run:

```bash
scripts/verify-core-assets.sh
scripts/check-android-native-bridge-guards.sh
```

Any upstream library change must fail the patch script until its symbols, call
site, instructions, and output hash have been reviewed again.
