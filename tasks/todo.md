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
- [ ] Commit and push `main`; require CI green
- [ ] Tag and publish `v3.4.0`; require Release green
- [ ] Verify GitHub, OSS, website, checksums, and provenance
- [ ] Update and read back durable SSRVPN project memory
