# Implementation Plan: Clash Service Boundaries and Conservative Unlock Probes

## Overview

Reduce the three remaining 900-line Clash service hotspots without changing
their public API or runtime behavior. Split configuration generation from
platform core lifecycle work, keep system-proxy ownership in the existing
platform services, and harden unlock classification so unknown official-page
content can never produce an `Available` result.

## Architecture Decisions

- Use private Dart `part` files and private mixins. This preserves the existing
  `ClashService` types and callers while making each responsibility readable.
- Do not introduce new public interfaces or dependencies. macOS and Windows
  already own dedicated `SystemProxyService` implementations.
- Keep platform initialization and bundled-asset installation in the main
  service files; move only configuration and core lifecycle/proxy coordination.
- Unknown unlock evidence always maps to `Inconclusive`. Only explicit known
  positive evidence may map to `Available`.

## Task List

### Phase 1: Structural Guard

- [x] Add a failing service-boundary guard for maximum main-file sizes,
      required parts, and system-proxy call placement.
- [x] Add the guard to the full verification pipeline.

### Phase 2: Shared Configuration Boundary

- [x] Move shared config caching and YAML helpers into a private config-support
      part without changing `ClashServiceBase` API.
- [x] Run shared config/base tests and analyzer, then commit.

### Phase 3: macOS Boundary

- [x] Move macOS config generation into a private config-support part.
- [x] Move macOS process lifecycle and system-proxy coordination into a private
      lifecycle part.
- [x] Run macOS Clash tests and analyzer, then commit.

### Phase 4: Windows Boundary

- [x] Move Windows config generation into a private config-support part.
- [x] Move Windows process lifecycle and system-proxy coordination into a
      private lifecycle part.
- [x] Run Windows Clash/config tests and analyzer, then commit.

### Phase 5: Conservative Unlock Evidence

- [x] Reproduce Netflix unknown-page and YouTube ambiguous-page false positives.
- [x] Require known positive evidence; otherwise return `Inconclusive`.
- [x] Run unlock tests and shared analyzer, then commit.

### Checkpoint: Complete

- [x] Structural guard passes and all three main service files are below limits.
- [x] Full verification passes with no coverage regression.
- [x] Private-node latency files and behavior remain unchanged.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| Private mixin member resolution changes behavior | Startup regression | Preserve code verbatim and run platform lifecycle tests after each move |
| System proxy cleanup moves out of sight | Proxy left enabled | Guard call placement and retain existing ownership tests |
| Refactor changes public surface | App compile failure | Keep the same `ClashService` and `ClashServiceBase` methods |
| Official page markup changes | False unlock result | Unknown or ambiguous bodies return `Inconclusive` |

## Open Questions

- None. The user explicitly selected these two follow-up items.
