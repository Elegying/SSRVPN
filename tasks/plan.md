# Implementation Plan: Package Guides, Flags, and Unlock Accuracy

## Overview

Prepare the next SSRVPN maintenance change without altering the private-node
latency display policy. The work covers Chinese package instructions, reliable
Windows flag rendering, conservative unlock/reachability results, and a final
three-platform quality review.

## Architecture Decisions

- Keep package instructions as plain UTF-8 text inside each distributable and
  verify both source text and built artifact contents.
- Render desktop flags from packaged SVG assets instead of platform emoji so
  Windows and macOS have deterministic output.
- Distinguish actual service-availability evidence from simple website/API
  reachability. Ambiguous responses must not be reported as supported.
- Keep external live checks out of deterministic CI; unit-test response
  classification and run a documented live audit during this task.

## Task List

### Phase 1: Packaging

- [ ] Add the specified Chinese four-step tutorial to the macOS DMG.
- [ ] Add the specified Chinese four-step usage section to the Windows ZIP.
- [ ] Guard source and built artifacts against missing or stale tutorials.

### Phase 2: Windows Flags

- [ ] Add a package-owned SVG flag widget with an explicit unknown fallback.
- [ ] Use it in the shared desktop node list so Windows does not depend on
      unsupported regional-indicator emoji rendering.
- [ ] Add a Windows widget regression test.

### Phase 3: Unlock Accuracy

- [ ] Reproduce current false positives/negatives with tests.
- [ ] Separate `Available`, `Reachable`, `Unavailable`, `Inconclusive`, and
      `Failed` outcomes in the UI.
- [ ] Bound redirects, response bytes, and all-test concurrency.
- [ ] Show concise evidence/details so results are auditable by users.

### Phase 4: Verification and Review

- [ ] Run focused tests after each increment.
- [ ] Run `make verify`, package smoke checks, macOS build, Android build/device
      smoke where relevant, and Windows CI-compatible tests.
- [ ] Review correctness, readability, architecture, security, and performance.
- [ ] Confirm private-node latency files are unchanged and their tests pass.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| External services change response text | Incorrect result | Use conservative fallback and explicit evidence strings |
| SVG flag package increases assets | Larger bundles | Use one maintained package only; measure resulting builds |
| Live checks are region-dependent | Flaky CI | Keep live audit manual and unit-test deterministic fixtures |
| Package tutorial regresses later | User confusion | Verify source text and built artifact contents |

## Open Questions

- None. The user explicitly approved completing all listed work; Windows
  real-device validation remains a handoff item if no Windows host is available.
