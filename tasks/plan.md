# Implementation Plan: Reliability and Operations Upgrade

## Overview

Improve SSRVPN's user-facing recovery, accessibility, diagnosability, measured
performance, and maintenance boundaries without changing the existing proxy
ownership rules or requiring signing credentials on ordinary builds. Windows 11
real-device acceptance remains explicitly deferred until the user has a Windows
machine.

## Architecture Decisions

- Define one shared typed error and diagnostic contract; platform services only
  provide OS-specific checks and safe repairs.
- Reuse the existing home log entry instead of adding a new navigation section.
- Repairs may only touch SSRVPN-owned state. They must never reset arbitrary
  system proxy, DNS, route, subscription, or user configuration.
- Add no runtime dependency for diagnostics, accessibility, or benchmarking.
- Measure performance with a deterministic local tool; do not add flaky timing
  thresholds to normal unit tests.
- Split large services only after behavior is covered, using same-library parts
  so public contracts and platform subclasses remain unchanged.
- Signing/notarization steps are optional and fail closed when explicitly
  enabled without credentials; unsigned development and personal builds remain
  supported.

## Task List

### Task 1: Shared error and diagnostic contract

**Acceptance criteria:**
- [x] Known core, port, permission, proxy, subscription, update, and config
      failures map to stable codes and actionable Chinese guidance.
- [x] Unknown errors remain safely redacted and never expose raw secrets.
- [x] Diagnostic reports have bounded text output and deterministic severity.

**Verification:** shared package tests and analyzer.

**Dependencies:** None.

### Task 2: Cross-platform diagnostic and repair center

**Acceptance criteria:**
- [x] Existing log entry opens diagnostics, current checks, and recent redacted
      logs on Android, macOS, and Windows.
- [x] Disconnected desktop users can retry recovery of SSRVPN-owned proxy state;
      connected users are never disconnected by the repair action.
- [x] Results can be copied as a bounded redacted report and rerun on demand.

**Verification:** shared widget tests, platform service tests, three analyzers.

**Dependencies:** Task 1.

### Checkpoint: Recovery UX

- [x] Error model tests fail before implementation and pass afterward.
- [x] Diagnostic UI exposes no raw subscription URLs or API secrets.
- [x] Existing connect, disconnect, and log flows remain green.

### Task 3: Accessibility and keyboard behavior

**Acceptance criteria:**
- [x] Connection/error/diagnostic status uses meaningful live semantics.
- [x] Icon-only actions have tooltips and semantic labels.
- [x] Desktop dialogs have deterministic initial focus and keyboard activation.

**Verification:** semantics widget tests for shared desktop and Android paths.

**Dependencies:** Task 2.

### Task 4: Reproducible performance baseline

**Acceptance criteria:**
- [x] A deterministic tool measures large subscription parse, merge, and config
      generation without network access or user data.
- [x] JSON output includes workload sizes, iterations, and elapsed samples.
- [x] Documentation explains how to compare results on the same machine.

**Verification:** tool self-check plus a smoke invocation from repository scripts.

**Dependencies:** Task 1.

### Task 5: Service responsibility splits

**Acceptance criteria:**
- [x] `subscription_service_base.dart` separates refresh/persistence and node
      editing/normalization while preserving its public API.
- [x] Platform settings persistence/secret handling is separated where it
      removes a distinct responsibility without cross-platform over-sharing.
- [x] Structure guards prevent the extracted responsibilities returning to the
      original monoliths.

**Verification:** existing subscription/settings suites, analyzer, structure guards.

**Dependencies:** Tasks 1 and 2.

### Task 6: Toolchain and signing readiness

**Acceptance criteria:**
- [x] Android uses the supported built-in Kotlin plugin path and native tests
      still pass.
- [x] Release automation can optionally sign/notarize macOS and sign Windows
      artifacts using secrets, with testable configuration validation.
- [x] Missing credentials keep ordinary unsigned builds working; explicit
      signing requests fail with a clear error.

**Verification:** Android Gradle tests, release-tool unit tests, workflow guards.

**Dependencies:** None.

### Checkpoint: Complete

- [x] `scripts/verify-all.sh` passes.
- [x] Final diff passes correctness, readability, architecture, security, and
      performance review.
- [x] Documentation and durable project memory reflect verified facts only.
- [x] `main` is pushed and final GitHub Android/macOS/Windows CI is green.

## Risks and Mitigations

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Repair action changes unrelated network state | Loss of connectivity | Require SSRVPN ownership and disconnected state before any repair |
| Diagnostics leak subscription data | Credential exposure | Reuse `LogRedactor`, bound output, and add hostile-input tests |
| Accessibility wrapper changes hit targets | UX regression | Wrap semantics without replacing native buttons; test activation |
| Timing checks become flaky | Noisy CI | Record benchmarks without hard wall-clock gates |
| Service split changes protected member lookup | Build/runtime regression | Same-library parts, mechanical move, existing behavior tests |
| Optional signing breaks free builds | Release outage | Separate explicit enable flags from credential presence and test both modes |

## Deferred

- Windows 11 clean-machine install/upgrade/restart acceptance matrix: deferred by
  the user until a Windows system is available.
- Actual Developer ID, Apple notarization, and Authenticode execution: blocked
  on external credentials, but the repository automation will be prepared.
