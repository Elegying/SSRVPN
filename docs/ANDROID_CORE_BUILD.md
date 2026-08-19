# Android embedded core build

## Scope

The Android app pins a source-built ARM64 `libgojni.so`. The committed bridge
preserves the reviewed JNI API and closes mixed, SOCKS, TUN, controller, and
runtime resources in `Bridge.stop()`.

## Source build

`scripts/build-android-core.sh` accepts only Go `1.25.11`, checks the fixed
Mihomo commit and tree, overlays the committed bridge, pins `x/mobile`, and uses
NDK r28c. The bridge calls Mihomo's existing `ReCreateMixed(0, nil)`,
`ReCreateSocks(0, nil)`, and `executor.Shutdown()` functions. The resulting
library must expose the six `bridge.Bridge` JNI methods and use 16 KiB alignment
for every ELF `LOAD` segment. Android builds use the `cmfa` tag so Mihomo uses
the host VPN service's socket protection and app routing contract instead of
trying to read the privileged `/data/system/packages.xml` database.

The external controller is intentionally not used as the shutdown signal. It is
managed by a separate embedded HTTP server and is closed and recreated when the
next configuration starts. Before reusing that occupied API port, Android
requires an authoritative idle native session and an authenticated `/version`
response from the current controller; otherwise normal collision-free fallback
selection remains in force. Android verifies release of the configured mixed
and SOCKS data-plane ports before accepting a clean disconnect.

## Verification

Run:

```bash
scripts/verify-core-assets.sh
scripts/check-android-native-bridge-guards.sh
```

Any source, toolchain, or library change must update the pinned provenance and
pass the ABI, ELF, lifecycle, and real-device checks before its content-addressed
asset can replace the current core.
