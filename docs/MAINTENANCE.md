# Maintenance Guide

This guide keeps local development, GitHub automation, and releases aligned.

## Weekly Maintenance

0. Start from a clean and synced local `main`:

   ```bash
   make status
   make sync
   ```

1. Check Dependabot PRs and CI status.
2. Run shared package verification:

   ```bash
   cd packages/ssrvpn_shared
   dart pub get
   dart analyze
   dart test --coverage=coverage
   ```

3. Run touched platform checks:

   ```bash
   cd SSRVPN_Android
   flutter pub get
   flutter analyze
   flutter test --coverage
   ```

4. Repeat for `SSRVPN_MacOS` and `SSRVPN_Windows` when shared behavior or common models change.
5. Keep `CHANGELOG.md` updated under `Unreleased`.

## Pull Request Rules

- Work from `feature/*`, `fix/*`, or `chore/*` branches; keep `main` stable.
- Put reusable business logic in `packages/ssrvpn_shared` before duplicating platform code.
- Keep platform services focused on native integration, process management, and OS-specific behavior.
- Redact credentials and subscription data in logs.
- Update tests when changing parsing, config generation, persistence, or release behavior.
- Include the verification commands in the PR template.
- Do not include local `dist/` files, signing material, or generated build caches.

## Release Checklist

1. Confirm `main` CI is green.
2. Review `CHANGELOG.md` and move relevant entries from `Unreleased` to the target version.
3. Verify signing material is available:
   - Android keystore or documented debug fallback.
   - macOS signing/notarization credentials when shipping outside local testing.
   - Windows code signing certificate when public trust is required.
   - See `docs/RELEASE_SIGNING.md` for expected secret names and workflow steps.
4. Create and push a version tag:

   ```bash
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

5. Watch the `Release` workflow.
6. Download artifacts and verify checksums.
7. Smoke test at least one install/run path per platform before announcing.

## Online/Offline Consistency

- Local `main` should track `origin/main`.
- Do not maintain platform-only repositories as active development roots.
- The old platform repositories should keep migration notices and no active CI.
- Any direct GitHub edit must be pulled locally before further local commits.
