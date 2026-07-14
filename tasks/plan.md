# Implementation Plan: SSRVPN 3.4.0 Windows Release Hardening

## Objective

Complete ten independent Windows-focused review rounds and ten adversarial
rounds, fix every confirmed defect with regression evidence, then publish and
verify a formal free-distribution release. The critical outcomes are:

- installation succeeds without administrator rights in the fixed per-user path;
- connect reaches a healthy authenticated Mihomo instance and reports reality;
- disconnect, exit, core loss, and recoverable crashes do not strand Windows proxy;
- unsigned distribution remains explicit, documented, checksummed, and reproducible.

## Architecture Decisions

- Preserve exact SSRVPN proxy ownership and the original proxy snapshot; never
  reset an unrelated proxy merely to make recovery appear successful.
- Use Windows-native Job Objects only as best-effort process containment. Restore
  networking before terminating surviving descendants.
- Keep PowerShell 5.1 source ASCII and make all external text encodings explicit.
- Keep the installer non-elevated under `%LOCALAPPDATA%\Programs\SSRVPN`; do not
  reintroduce data migration, paid signing, or restart replacement.
- Treat GitHub Windows runners as automated integration evidence, not as a
  substitute for the deferred Windows 11 human acceptance matrix.

## Phases and Checkpoints

1. Freeze repository/release baseline and create a 20-round evidence matrix.
2. Complete normal reviews N1-N10; each finding needs file/behavior evidence.
3. Complete adversarial reviews A1-A10; reproduce or prove each hostile case.
4. Add failing regression tests, implement the smallest durable fixes, and rerun
   the matching checks after every slice.
5. Run all analyzers, Flutter suites, native tests, coverage, release tooling,
   asset verification, secret scanning, and Windows workflow guards.
6. Curate the `3.4.0` changelog, user docs, rollback notes, and release metadata.
7. Commit and push `main`; require every online CI job, including Windows package
   install/uninstall smoke, to be green.
8. Tag `v3.4.0`; require the Release workflow, GitHub assets, provenance, OSS
   immutable directory/public aliases, and website download paths to agree.

## Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| Installer deletes state before proving processes are closed | Block before `[InstallDelete]`; test locked-process failure |
| Core dies after proxy activation | Observe exit, restore proxy, permit only one intent-safe restart |
| Forced app exit leaves dead proxy | Native launcher recovery plus validated persistent ownership journal |
| Other software changes the proxy | Exact ownership checks; preserve recovery evidence instead of overwriting |
| PowerShell 5.1 misdecodes localized data | ASCII scripts, explicit UTF-8 I/O, real PS5.1 CI execution |
| Unsigned installer is distrusted | Clear SmartScreen guidance, SHA-256/provenance, canonical HTTPS sources |
| GitHub and OSS publish different versions | Draft-first transaction, compensation path, post-release public downloads |
| Automated checks overclaim Windows UX | Record skipped/native-only evidence and retain the human matrix explicitly |

## Release Acceptance

- [x] All twenty review rows are closed with evidence and no unresolved P0-P2.
- [x] Local verification is green apart from explicitly documented OS-only skips.
- [x] `main` CI is green on Android, macOS, and Windows.
- [ ] `v3.4.0` Release is public and all assets/checksums/provenance verify.
- [ ] OSS fixed aliases and website paths download the same `v3.4.0` artifacts.
- [ ] Rollback to `v3.3.5` remains operational if release validation fails.
