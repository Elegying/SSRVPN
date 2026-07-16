# Project Management

SSRVPN is maintained as a trunk-based monorepo. The goal is to keep `main` stable, keep local work easy to recover, and make every release reproducible from GitHub.

## Branch Model

- `main`: stable source of truth. CI should be green.
- `feature/<short-name>`: user-visible features.
- `fix/<short-name>`: bug fixes.
- `chore/<short-name>`: maintenance, dependency, documentation, and tooling work.
- `archive/<short-name>`: preserved local or historical work that is not part of the active release line.
- `vX.Y.Z` tags: release triggers.

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

For targeted changes, run at least the shared package checks plus the touched platform:

```bash
cd packages/ssrvpn_shared && dart analyze && dart test
cd SSRVPN_Android && flutter analyze && flutter test
```

## Release Policy

1. Confirm `main` is clean and synced.
2. Confirm CI is green.
3. Update `CHANGELOG.md`.
4. Create an annotated version tag: `vX.Y.Z`.
5. Push the tag to trigger the release workflow.
6. Download artifacts, verify checksums, and smoke test installation.

Current personal releases use the free path:

- Android self-signed release keystore,
- macOS ad-hoc signing without notarization,
- Windows unsigned per-user installer only.

Paid Apple Developer ID notarization and Windows Authenticode signing are intentionally out of scope. Do not add certificate secrets or optional paid-signing branches unless this product decision is explicitly replaced.

See `docs/RELEASE_SIGNING.md`.
