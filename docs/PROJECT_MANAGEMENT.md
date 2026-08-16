# Project Management

SSRVPN is maintained as a trunk-based monorepo. The goal is to keep `main` stable, keep local work easy to recover, and make every release reproducible from GitHub.

## Branch Model

- `main`: stable source of truth. CI should be green.
- `feature/<short-name>`: user-visible features.
- `fix/<short-name>`: bug fixes.
- `chore/<short-name>`: maintenance, dependency, documentation, and tooling work.
- `archive/<short-name>`: preserved local or historical work that is not part of the active release line.
- `vX.Y.Z` tags: immutable release triggers created by the `Prepare Release` workflow.

## Source vs Artifacts

Commit source, tests, docs, and automation.

Do not commit:

- local `dist/` deliverables,
- APK/DMG/EXE/ZIP files,
- Android keystores or `key.properties`,
- certificates, provisioning profiles, `.env` files,
- Flutter/Gradle/Xcode/Visual Studio build caches.

Release artifacts belong in GitHub Releases. Local copies belong in `dist/`.

## Local Workflow

Use the root `Makefile` for common tasks:

```bash
make status
make sync
make feature name=my-change
make verify
```

`make sync` refuses to run when the working tree has local changes. This avoids accidentally overwriting work.

## Verification Gate

Before merging or releasing:

```bash
make verify
```

This gate includes tracked Dart formatting, ShellCheck, strict analysis, secrets and release guards, documentation consistency, coverage, and the native checks available on the current host. Pull requests must also pass Dependency Review and target-platform CI; a green macOS run does not replace Windows-native build, registry, PowerShell, or installer evidence.

For targeted changes, run at least the shared package checks plus the touched platform:

```bash
cd packages/ssrvpn_shared && dart analyze && dart test
cd SSRVPN_Android && flutter analyze && flutter test
```

## Release Policy

1. Confirm `main` is clean and synced.
2. Confirm CI is green.
3. Merge the matching application version and `CHANGELOG.md` entry into `main`.
4. Run GitHub Actions `Prepare Release` with the new `vX.Y.Z` tag. The workflow refreshes and verifies GeoIP, validates the generated branch and final `main`, creates the annotated tag, and dispatches `Release`. Do not create or push the version tag manually.
5. Approve the protected release environment when required and wait for the public, non-draft Release.
6. Download the published artifacts, verify checksums, and smoke test installation.

Current personal releases use the free path:

- Android self-signed release keystore,
- macOS ad-hoc signing without notarization,
- Windows unsigned per-user installer only.

Paid Apple Developer ID notarization and Windows Authenticode signing are intentionally out of scope. Do not add certificate secrets or optional paid-signing branches unless this product decision is explicitly replaced.

See [ADR-012](decisions/012-automatic-release-preparation.md), the [release checklist](RELEASE_CHECKLIST.zh-CN.md), and [release signing](RELEASE_SIGNING.md).
