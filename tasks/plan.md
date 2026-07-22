# Historical Implementation Plan: SSRVPN 3.4.0 Windows Release Hardening

> Historical record: this plan was completed with the v3.4.0 release. It is
> retained as execution evidence, not as the project's current implementation
> plan. See [project health](../docs/PROJECT_HEALTH.md) and the
> [roadmap](../docs/ROADMAP.md) for current status and priorities.

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
- [x] `v3.4.0` Release is public and all assets/checksums/provenance verify.
- [x] OSS fixed aliases and website paths download the same `v3.4.0` artifacts.
- [x] Rollback to `v3.3.5` remains operational if release validation fails.

---

# Implementation Record: 2026-07-20 User-Journey Reliability Fixes

## Objective

Fix every confirmed issue from the 2026-07-20 three-platform user-journey
review, then complete a fresh five-axis and adversarial review. Preserve the
explicit product boundaries: HTTP subscription policy is unchanged, Windows
remains installer-only and unsigned, and all platforms retain only Home and
Subscriptions.

## Architecture Decisions

- Make subscription deletion transactional: a failed refresh of the remaining
  sources must roll the deletion back and preserve the last-known-good state.
- Give refresh and latency work explicit operation generations and cancellation
  boundaries so stale asynchronous results cannot mutate current UI state.
- Preserve proxy recovery fail-safe behavior on desktop platforms; improve
  visibility and retry behavior without killing a core that is still protecting
  an owned system-proxy endpoint.
- Reuse the canonical subscription URL redactor and existing update-verification
  pipeline; add no dependency for these fixes.
- Move only measured large YAML/config work off the Flutter UI isolate while
  retaining small-input behavior and deterministic output.

## Phases and Checkpoints

1. Add regression tests and repair subscription deletion, batch refresh
   deadline/cancellation, and partial-failure preservation.
2. Add operation generations/cancellation for Android and desktop batch latency
   tests, including stale same-name node protection.
3. Repair Android permission/privacy/update paths, Windows installer/launcher
   ownership paths, and macOS recovery/exit visibility in isolated platform
   slices.
4. Repair shared crash-report handling, update discovery, network guidance, and
   measured large-subscription UI-isolate work.
5. Run targeted suites after every slice, then `make verify`, platform-native
   gates, structural/security guards, performance benchmarks, dead-code scans,
   and a fresh-context adversarial review.

## Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| Cancelled refresh completes late and overwrites newer state | Operation generation checked before every shared-state commit |
| Delete rollback leaves metadata/cache split | Defer persistence until refresh commit; test disk and memory state |
| Latency cancellation leaks old callbacks | Generation-scoped result sink plus stale-completion tests |
| Windows ignores a real SSRVPN TUN residue | Require stronger ownership evidence and retain fail-closed owned-residue tests |
| macOS visible recovery change weakens proxy safety | Keep existing restore-before-kill rule; test retry and failed-exit behavior |
| Isolate conversion changes generated YAML | Compare byte-for-byte output in unit tests and rerun benchmarks |

## Acceptance

- [x] Every confirmed finding has a regression test or target-platform guard.
- [x] Targeted tests pass after each incremental slice.
- [x] Repository-wide verification, coverage gates, and native tests pass.
- [x] Final five-axis and adversarial reviews have no Critical or Required issue.
- [x] Working tree contains only intentional source/test/documentation changes.
- [x] At the original review checkpoint, no commit, push, tag, release, or
  release artifact build was performed; the user's later explicit publication
  request supersedes that temporary delivery boundary.

---

# Implementation Plan: 2026-07-22 Deep Reliability Hardening

## Objective

Complete a code-level, three-platform review and repair of connection
lifecycles, port ownership, responsive UI, verified updates/overwrite installs,
and subscription-to-runtime configuration generation. Real-device acceptance
is intentionally deferred to the user; automated and static evidence must not
be described as device evidence.

## Architecture Decisions

- Preserve connection intent separately from observed core health. At most two
  bounded, cancellable recoveries may continue only while the same user connect
  intent is current; disconnect and quit always win.
- Treat ports, core/service identity, active config, and system proxy/TUN state
  as one lifecycle transaction. Never terminate or overwrite an unowned
  process merely because it occupies a preferred port.
- Keep the current HTTP subscription policy, installer-only unsigned Windows
  distribution, free macOS signing boundary, and Home/Subscriptions product
  surface unchanged.
- Keep user data outside Windows program-file rollback. Update recovery may
  publish only an artifact whose expected SHA-256 is known and revalidated.
- Ignore subscription rule/group sections by design; import runnable proxy
  nodes, reserve SSRVPN runtime group names, and write one deterministic,
  validated rule order with user force-proxy entries before direct rules.
- Use bounded scroll regions and flexible text for constrained windows and
  large text scaling without truncating the underlying node/subscription value.

## Phases and Checkpoints

1. Freeze `origin/main` v3.4.11 and collect read-only findings across the four
   requested areas.
2. Add failing regression tests for every confirmed defect before changing its
   production path.
3. Repair lifecycle/port cleanup and bounded intent-preserving recovery on all
   three platforms.
4. Repair constrained-window dialogs, stacked notices, diagnostic headers, and
   long update-error presentation.
5. Repair checksum-bound interrupted-download recovery and Windows overwrite
   installation rollback while preserving installed user data.
6. Reserve runtime proxy-group names, deduplicate generated groups/rules, and
   validate deterministic subscription/config output.
7. Run focused suites after each slice, then analyzers, native/static guards,
   installer tests, and repository-wide `make verify`.
8. Perform a fresh-context adversarial review of the complete diff, repair any
   confirmed regression, and produce a detailed Chinese audit report.

## Risks and Mitigations

| Risk | Mitigation |
| --- | --- |
| Recovery fights a manual disconnect or quit | Generation-bound cancellation checked before every restart commit |
| Port preflight races another process | Detect explicit bind/start conflicts, regenerate runtime config, and retry only within a bounded transaction |
| DNS recovery loops forever after a network service disappears | Distinguish confirmed service removal from transient command failure; preserve fail-closed behavior for uncertainty |
| PID reuse terminates an unrelated process | Versioned identity includes creation time and canonical executable identity; legacy records fail closed |
| Installer failure destroys the working version | Program-only rollback journal on the same volume; never include `bin\\ssrvpn` user data |
| Interrupted download restores a misleading artifact | Recompute expected SHA-256 before publishing any `.previous` file |
| Large text hides actions | Viewport-bounded scrolling plus widget tests at constrained sizes and high text scale |
| Subscription names collide with generated groups | Stable reserved-name allocation and parsed-config assertions |

## Acceptance

- [x] Every confirmed P1/P2 issue has a regression test or a target-specific
      structural guard.
- [x] Manual disconnect, normal quit, forced-exit recovery, port collision, and
      restart semantics remain mutually consistent in code and tests.
- [x] Update recovery never promotes an unverified artifact; failed Windows
      overwrite installation restores the previous runnable program without
      modifying installed user data.
- [x] Constrained-window/high-text-scale UI tests have no overflow and retain
      reachable primary actions.
- [x] Generated Mihomo YAML parses deterministically with unique runtime names
      and force-proxy precedence intact.
- [x] Focused suites, platform static/native guards, and final `make verify`
      pass; any OS-only skips are listed explicitly.
- [x] Fresh-context review has no unresolved Critical/Required finding.
- [x] No push, tag, release, or online build is performed in this task unless
      separately requested.
