# SSRVPN 3.4.0 Windows Release Hardening

## Normal review rounds

- [x] N1 Installer flow and per-user permissions
- [x] N2 Connect state machine and concurrency
- [x] N3 Disconnect, exit, and proxy restoration
- [x] N4 Mihomo process lifecycle and recovery
- [x] N5 Encoding, localization, and PowerShell 5.1
- [x] N6 Filesystem, secrets, permissions, and path safety
- [x] N7 Subscription/network input and timeout boundaries
- [x] N8 Tray, UI status, diagnostics, update, and accessibility
- [x] N9 CI, packaging, release transaction, and supply chain
- [x] N10 Maintainability, performance, observability, and documentation

## Adversarial review rounds

- [x] A1 PowerShell 5.1 and hostile code-page environment
- [x] A2 Locked files, antivirus delay, partial install, and Unicode paths
- [x] A3 Rapid connect/disconnect/reconnect/exit races
- [x] A4 Kill core/app/launcher and reboot-like interruption
- [x] A5 Forged/stale recovery journal and external proxy mutation
- [x] A6 Malicious, oversized, compressed, redirected, or stalled subscription
- [x] A7 Port collision, slow core, API auth failure, and startup timeout
- [x] A8 Read-only/symlink/path replacement and permission denial
- [x] A9 GitHub/OSS split-brain, corrupt artifact, and failed promotion
- [x] A10 Clean machine, missing runtime, unsigned warnings, logs, and rollback

## Delivery

- [x] Fix every confirmed issue with a failing regression first
- [x] Run repository-wide verification and coverage thresholds
- [x] Complete final five-axis and adversarial diff review
- [x] Update version/changelog/docs/audit report to `3.4.0`
- [x] Commit and push `main`; require CI green
- [x] Tag and publish `v3.4.0`; require Release green
- [x] Verify GitHub, OSS, website, checksums, and provenance
- [x] Update and read back durable SSRVPN project memory

---

# 2026-07-20 User-Journey Reliability Fixes

> This checklist records the completed pre-publication review. The user's later
> explicit publication request supersedes the earlier local-only checkpoint.

## Shared data and async state

- [x] Make subscription deletion transactional and preserve last-known-good data
- [x] Add total refresh deadline and user cancellation with stale-result guards
- [x] Make batch latency single-flight/generation-safe across Android and desktop
- [x] Show update discoveries without requiring a successful VPN connection
- [x] Keep copied crash reports until the user explicitly deletes them
- [x] Move measured large YAML/config work off the UI isolate without drift

## Platform fixes

- [x] Android: permission wait, URL redaction, network guidance, APK deadline
- [x] Windows: owned TUN detection and visible mutex/recovery conflicts
- [x] macOS: startup recovery, unexpected exit, quit failure, tray failure visibility

## Verification and review

- [x] Run shared and platform targeted tests after each slice
- [x] Run analyzers, native tests, coverage, security and structural guards
- [x] Run before/after performance benchmark
- [x] Inspect dead code, UI wording and explicit product exclusions
- [x] Complete fresh-context adversarial review and reconcile every finding
- [x] Run final `make verify` and confirm a clean, intentional diff

---

# 2026-07-22 Deep Reliability Hardening

## Lifecycle and ports

- [x] Retire a macOS TUN DNS journal when its captured network service is
      conclusively gone, then release the core, lock, runtime files, and ports
- [x] Preserve user connection intent through two bounded control-plane/core
      recoveries; cancel immediately on disconnect or quit
- [x] Connect Android to runtime port preparation and cover a pre-start port
      collision without taking ownership of another process
- [x] Upgrade Windows stale-core identity from PID-only to generation-aware and
      reject legacy/changed identities

## Responsive UI

- [x] Make Android and desktop tutorial content viewport-bounded and scrollable
- [x] Bound and scroll stacked desktop startup/runtime notices
- [x] Make Android and desktop diagnostic sheet headers flexible at large text
- [x] Make long update errors bounded, sanitized, and scrollable

## Update and overwrite install

- [x] Revalidate `.previous` downloads against the expected SHA-256 before
      publishing them under an official asset name
- [x] Stop Windows stale cleanup from promoting an unverifiable `.previous`
      file
- [x] Add program-only Windows overwrite rollback/journal recovery while
      preserving `bin\\ssrvpn` settings, subscriptions, and secrets

## Subscription and runtime configuration

- [x] Reserve built-in runtime proxy-group names during node merge
- [x] Deduplicate/reject colliding generated extra groups and deterministic
      rules without changing force-proxy precedence
- [x] Parse and assert the final generated YAML in regression tests

## Verification and delivery

- [x] Run each new regression red, implement the minimum repair, then rerun
- [x] Run focused shared/Android/macOS/Windows/installer suites
- [x] Run analyzers, format checks, shell/native/static guards, and `make verify`
- [x] Complete fresh-context adversarial diff review and repair findings
- [x] Produce the detailed Chinese code-audit and repair report

## 2026-07-22 Nine-item follow-up verification

- [x] Allow two bounded recovery attempts across Android, macOS, and Windows
- [x] Gate macOS DMG opening on a successful safe disconnect and require quit
      before replacing the running app
- [x] Confirm desktop runtime notices, long-node overflow, missing SHA failure,
      Windows update startup, subscription name merge, and force-rule ordering
- [x] Rerun repository-wide `make verify` and record the final evidence
