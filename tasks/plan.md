# Implementation Plan: SSRVPN 3.0.0 Production Release

## Overview

Treat `v3.0.0` as a public production release for Android, macOS, and Windows.
Re-audit the complete delta from `main`, validate startup, configuration,
system-proxy ownership, packaging, update, and rollback paths, then merge the
verified release commit to `main`, tag it, and monitor the tag-driven GitHub
release until all signed/checksummed artifacts are published.

## Release Decisions

- Version: `3.0.0+300` across shared constants and all platform pubspecs.
- Source: only a commit already merged to `main` may receive `v3.0.0`.
- Android/macOS get local release builds and real-machine checks where possible;
  Windows receives local source/tests plus mandatory Windows GitHub runner build.
- Existing `v3.0.0` tags/releases must never be overwritten.
- Rollback is the immutable `v2.5.0` release; a blocking post-release defect is
  handled by removing the new release from distribution and issuing a new tag,
  never by moving `v3.0.0`.

## Task List

### Phase 1: Release Baseline

- [x] Confirm repository, branch cleanliness, remote, and authenticated GitHub access.
- [x] Confirm `v3.0.0` is free locally and remotely.
- [x] Record the exact `main...HEAD` release delta and public behavior changes.

### Phase 2: Formal Three-Platform Audit

- [x] Review tests first, then correctness, readability, architecture, security,
      and performance for every release-delta file.
- [x] Trace startup, core lifecycle, configuration generation, and system-proxy
      cleanup paths for Android, macOS, and Windows.
- [x] Audit dependencies, secrets, update verification, release workflows,
      package contents, and known platform limitations.
- [x] Resolve every release-blocking finding with a regression check.

### Checkpoint: Release Candidate

- [x] No Critical or Required review findings remain.
- [x] “Private car” latency policy remains unchanged.
- [x] Windows-only validation gaps are explicitly delegated to required CI jobs.

### Phase 3: Version and Release Notes

- [x] Set all version sources to `3.0.0+300`.
- [x] Add a curated user-facing `3.0.0` changelog entry.
- [x] Run version, guide, secret, and release-source checks.

### Phase 4: Local Production Validation

- [x] Run `scripts/verify-all.sh` and all coverage gates.
- [x] Build and validate the macOS Release app and DMG on this Mac.
- [ ] Build the Android Release APK, verify identity/signature, install it on the
      authorized Android device, and smoke startup/connection lifecycle.
- [x] Run native macOS lifecycle tests and artifact smoke checks.

### Phase 5: Remote CI and Merge

- [ ] Push the release candidate branch.
- [ ] Create/update the PR to `main`; require all three platform jobs to pass.
- [ ] Merge without bypassing failed checks, then verify remote `main` SHA.

### Phase 6: Publish 3.0.0

- [ ] Create and push annotated tag `v3.0.0` from the verified `main` commit.
- [ ] Monitor the Release workflow through Android, macOS, Windows, and publish jobs.
- [ ] Verify the public release and all six non-empty artifacts/checksums.
- [ ] Run `scripts/check-release-assets.sh v3.0.0`.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Windows cannot be executed locally on macOS | User-facing Windows regression | Mandatory Windows GitHub build/test/package job before tag |
| Major version metadata diverges | Update/release failure | Existing version-sync guard plus tag/version check |
| Desktop proxy remains enabled after failure | User loses normal networking | Ownership tests, startup ordering guard, lifecycle review |
| Release artifact is unsigned or malformed | Installation failure or trust warning | APK signature check, macOS strict ad-hoc validation, package smoke checks |
| Remote tag already exists | Immutable release collision | Local, remote tag, and GitHub release checks before tag creation |

## Open Questions

- Cross-model second opinion is optional and non-blocking unless the user requests it.
