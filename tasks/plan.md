# Implementation Plan: Maintainability Refactor

## Overview

Reduce the largest actively edited Dart files without changing user-visible
behavior. The refactor follows existing Dart `part` and extension boundaries so
macOS, Windows, and Android keep their current service contracts while future UI
and runtime changes land in smaller responsibility-focused files.

## Architecture Decisions

- Share the duplicated macOS/Windows navigation shell as one package-owned Dart
  part; keep platform startup and shutdown policy in each platform app.
- Split view composition from connection-option widgets in the shared desktop
  dashboard; both desktop entrypoints continue to include the same parts.
- Split Android home runtime actions and public-IP state into extensions of the
  existing state class; do not introduce a new controller or dependency.
- Add line-count and required-part guards before moving code so the repository
  cannot silently regress to the previous monoliths.

## Task List

### Phase 1: Synchronize verified work

- [x] Confirm local `main` is clean and exactly five commits ahead of `origin/main`.
- [x] Push the verified commits and confirm the remote branch SHA.
- [x] Confirm the push-triggered SSRVPN CI run started.

### Phase 2: Consolidate the desktop application shell

- [x] Add a failing boundary check for oversized platform `app.dart` files and
      the required shared shell part.
- [x] Move the duplicated navigation, responsive shell, and startup banner UI to
      one shared part while retaining platform-specific startup failure text.
- [x] Run desktop guard, analyzer, macOS tests, and Windows tests.

### Checkpoint: Desktop shell

- [x] Both platform `app.dart` files stay below the new boundary.
- [x] macOS and Windows use the same shell implementation.
- [x] No startup, tray, shutdown, or navigation behavior changes.

### Phase 3: Split oversized feature files

- [x] Split shared desktop dashboard composition/status from connection options.
- [ ] Split Android home public-IP and runtime actions from lifecycle/state setup.
- [ ] Add required-part and line-count guards for both boundaries.
- [ ] Run focused guards, analyzer, shared tests, and Android tests.

### Checkpoint: Complete

- [ ] Run `scripts/verify-all.sh` successfully.
- [ ] Review the final diff for correctness, readability, architecture, security,
      and performance.
- [ ] Commit each verified slice, push `main`, and require green SSRVPN CI.
- [ ] Update project health documentation and durable project memory.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Dart part directives diverge between macOS and Windows | One desktop build fails | Guard both entrypoints and run both platform analyzers/tests |
| Moving state methods changes member lookup | Android compile/runtime regression | Use same-library extensions and run analyzer plus Android tests |
| Mechanical moves accidentally alter UI | Visual or behavioral regression | Preserve code verbatim and keep each move in an isolated commit |
| Refactor grows scope into architecture redesign | Higher regression risk | No new dependency, controller, or public service contract |

## Open Questions

- None. This pass is behavior-preserving and does not require a version bump,
  tag, or release.
