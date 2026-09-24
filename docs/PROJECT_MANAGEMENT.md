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
4. Run GitHub Actions `Prepare Release` with the new `vX.Y.Z` tag. The workflow verifies the repository-pinned core assets and final `main`, creates the annotated tag, and dispatches `Release`. It does not check or update upstream GeoIP. Do not create or push the version tag manually.
5. Approve the protected release environment when required and wait for the public, non-draft Release.
6. Download the published artifacts, verify checksums, and smoke test installation.

Current personal releases use the free path:

- Android self-signed release keystore,
- macOS ad-hoc signing without notarization,
- Windows unsigned installer in administrator mode, with a default program path under the current user's LocalAppData and uninstall registration in HKLM64.

Paid Apple Developer ID notarization and Windows Authenticode signing are intentionally out of scope. Do not add certificate secrets or optional paid-signing branches unless this product decision is explicitly replaced.

See [ADR-014](decisions/014-manual-only-geoip-updates.md), the [release checklist](RELEASE_CHECKLIST.zh-CN.md), and [release signing](RELEASE_SIGNING.md).

## Public Release Retention

The public download list keeps the current stable client release. The
`core-assets-v1` prerelease is retained separately as required build infrastructure;
it is not a client download or an update candidate. Historical version tags and
source history remain intact.

Retiring old Release listings requires an explicit maintainer decision, a complete
local backup of their metadata and assets, and verified durable copies of any
artifacts still used by regression tests. Never delete the current client, move a
published tag, or recreate an immutable release under the same tag.

Windows legacy catalog sources are pinned in
[`scripts/windows_legacy_installer_sources.json`](../scripts/windows_legacy_installer_sources.json).
Their original GitHub URL, release ID, asset ID and SHA-256 remain provenance;
`url` points to the byte-identical, versioned OSS archive used by tests. These
historical installers are test fixtures, not supported update candidates.

`Maintenance > windows-installer-archive`, dispatched from `main`, fills only
missing EXE archives after verifying the original bytes. Existing objects must
match; uploads use `--ignore-existing` and anonymous full-file readback. The task
does not delete Releases, overwrite archives, promote fixed download URLs or
modify `latest.json`. Before retiring listings, verify all baseline hashes and
run the Windows catalog/ownership and public-installer checks in disposable CI.
OSS remains outside the client updater's trust path.
