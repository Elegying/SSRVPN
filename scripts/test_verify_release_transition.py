import importlib.util
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("verify-release-transition.py")
TAG_SOURCE_GUARD = Path(__file__).with_name("verify-release-tag-source.sh")
WAIT_FOR_PUBLIC_RELEASE = Path(__file__).with_name(
    "wait-for-github-release-public.sh"
)
SPEC = importlib.util.spec_from_file_location("release_transition", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)


class VerifyReleaseTransitionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        SPEC.loader.exec_module(MODULE)

    def test_accepts_newer_and_idempotent_versions(self) -> None:
        MODULE.require_monotonic_release("3.2.0", "3.1.9")
        MODULE.require_monotonic_release("3.1.1", "3.1.1")

    def test_rejects_older_release(self) -> None:
        with self.assertRaisesRegex(ValueError, "older than public version"):
            MODULE.require_monotonic_release("3.1.0", "3.1.1")

    def test_new_tag_must_be_strictly_newer_than_highest_existing_tag(self) -> None:
        MODULE.require_newer_release("3.2.0", "3.1.9")
        with self.assertRaisesRegex(ValueError, "newer than previous release"):
            MODULE.require_newer_release("3.1.9", "3.1.9")
        with self.assertRaisesRegex(ValueError, "newer than previous release"):
            MODULE.require_newer_release("3.1.8", "3.1.9")

    def test_compares_numeric_components(self) -> None:
        MODULE.require_monotonic_release("3.10.0", "3.9.9")

    def test_android_build_code_must_strictly_increase(self) -> None:
        MODULE.require_increasing_build_code(312, 311)
        with self.assertRaisesRegex(ValueError, "must be greater"):
            MODULE.require_increasing_build_code(311, 311)

    def test_gradle_distribution_is_integrity_pinned(self) -> None:
        wrapper = (
            SCRIPT.parents[1]
            / "SSRVPN_Android"
            / "android"
            / "gradle"
            / "wrapper"
            / "gradle-wrapper.properties"
        ).read_text(encoding="utf-8")
        self.assertIn("gradle-9.1.0-bin.zip", wrapper)
        self.assertIn(
            "distributionSha256Sum="
            "a17ddd85a26b6a7f5ddb71ff8b05fc5104c0202c6e64782429790c933686c806",
            wrapper,
        )

    def test_release_workflow_has_immutable_publish_guards(self) -> None:
        workflow = (SCRIPT.parents[1] / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("group: ssrvpn-public-release", workflow)
        self.assertIn("overwrite_files: false", workflow)
        self.assertIn("ANDROID_RELEASE_CERT_SHA256", workflow)
        self.assertIn("verify-release-transition.py", workflow)
        self.assertIn("--target-build-code", workflow)
        self.assertIn("--current-version", workflow)
        self.assertIn('if [ "$release_commit" != "$main_tip" ]', workflow)
        self.assertIn("validate-existing-release-retry.py", workflow)
        self.assertIn("releases/tags/$GITHUB_REF_NAME", workflow)
        self.assertIn("SSRVPN-release-provenance.json", workflow)
        self.assertIn("generate-release-provenance.py", workflow)
        self.assertIn('--expected-commit "$release_commit"', workflow)
        self.assertIn("--ignore-existing", workflow)
        self.assertIn('cmp "$file" "$downloaded"', workflow)
        self.assertNotIn("Sync latest geoip.metadb", workflow)
        self.assertNotIn("scripts/sync-geoip-metadb.py", workflow)
        self.assertGreaterEqual(
            workflow.count("scripts/run-flutter-coverage.sh"),
            4,
        )
        for target in (
            "packages/ssrvpn_shared",
            "SSRVPN_Android",
            "SSRVPN_MacOS",
            "SSRVPN_Windows",
        ):
            self.assertIn(
                f"scripts/check-coverage-thresholds.sh {target}", workflow
            )

        validate = workflow.index("Validate OSS publishing configuration")
        github_release = workflow.index("Create GitHub Draft Release")
        self.assertLess(validate, github_release)
        validation_step = workflow[validate:github_release]
        self.assertIn(
            "packages/ssrvpn_shared/lib/services/update_checker.dart",
            validation_step,
        )
        self.assertIn("primaryManifestUrl", validation_step)
        self.assertIn("os.environ['OSS_BUCKET']", validation_step)
        self.assertIn("os.environ['OSS_ENDPOINT']", validation_step)
        self.assertIn("os.environ['OSS_PREFIX']", validation_step)
        self.assertIn("configured_url != match.group(1)", validation_step)
        retry_reuse = workflow.index("Reuse an existing GitHub release on retry")
        self.assertLess(validate, retry_reuse)
        self.assertLess(retry_reuse, github_release)
        self.assertIn("scripts/reuse-github-release-assets.sh", workflow)
        self.assertIn("steps.existing_release.outputs.exists != 'true'", workflow)
        oss_publish = workflow.index("Publish immutable release to OSS")
        github_finalize = workflow.index('gh release edit "$tag" --draft=false')
        self.assertLess(github_release, oss_publish)
        public_promote = workflow.index("Promote OSS public channel")
        self.assertLess(oss_publish, public_promote)
        self.assertLess(public_promote, github_finalize)
        self.assertIn("scripts/promote-oss-public-channel.sh", workflow)
        self.assertIn("OSS_PRESERVE_BACKUP=1", workflow)
        self.assertIn('--restore "$backup_dir"', workflow)
        self.assertIn("--prerelease=false --latest", workflow)
        self.assertIn("scripts/wait-for-github-release-public.sh", workflow)
        self.assertRegex(
            workflow,
            r'scripts/wait-for-github-release-public\.sh\s+\\?\s*'
            r'"\$tag" 5 attempted',
        )
        publication_poll = WAIT_FOR_PUBLIC_RELEASE.read_text(encoding="utf-8")
        self.assertIn("--json isDraft,isPrerelease", publication_poll)
        self.assertIn("Preserve OSS recovery backup", workflow)

        published_verify = workflow.index(
            "Verify published GitHub and OSS channels"
        )
        self.assertLess(github_finalize, published_verify)
        verify_step = workflow[published_verify:]
        self.assertIn('scripts/check-release-assets.sh "$tag"', verify_step)
        self.assertIn(
            'gh api "repos/$GITHUB_REPOSITORY/releases/tags/$tag"',
            verify_step,
        )
        prerelease_guard = verify_step.index(
            'if [ "$is_prerelease" != true ]; then'
        )
        latest_lookup = verify_step.index(
            'gh api "repos/$GITHUB_REPOSITORY/releases/latest"'
        )
        self.assertLess(prerelease_guard, latest_lookup)
        self.assertNotIn("releases/latest", verify_step[:prerelease_guard])
        self.assertIn("latest.get(\"id\") != release.get(\"id\")", verify_step)
        self.assertIn("$OSS_PREFIX/latest.json", verify_step)
        self.assertIn(
            "?verify=${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${attempt}",
            verify_step,
        )
        self.assertIn("Cache-Control: no-cache", verify_step)
        self.assertIn("set(manifest_by_name) != binaries", verify_step)
        self.assertIn(
            'manifest_asset.get("sha256") != github_digest', verify_step
        )
        self.assertIn(
            'manifest_asset.get("url") != f"{release_base_url}/{name}"',
            verify_step,
        )

    def _poll_public_release(
        self,
        root: Path,
        states: list[str],
        mutation_state: str = "attempted",
    ) -> tuple[subprocess.CompletedProcess[str], int]:
        bin_dir = root / "bin"
        bin_dir.mkdir()
        state_file = root / "states"
        state_file.write_text("\n".join(states) + "\n", encoding="utf-8")
        counter_file = root / "counter"
        fake_gh = bin_dir / "gh"
        fake_gh.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                count=0
                if [ -f "$FAKE_GH_COUNTER" ]; then
                  count="$(cat "$FAKE_GH_COUNTER")"
                fi
                count=$((count + 1))
                printf '%s\n' "$count" > "$FAKE_GH_COUNTER"
                state="$(sed -n "${count}p" "$FAKE_GH_STATES")"
                if [ "$state" = FAIL ]; then
                  exit 1
                fi
                printf '%b\n' "$state"
                """
            ),
            encoding="utf-8",
        )
        fake_sleep = bin_dir / "sleep"
        fake_sleep.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
        fake_gh.chmod(0o755)
        fake_sleep.chmod(0o755)
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{bin_dir}:{env['PATH']}",
                "FAKE_GH_STATES": str(state_file),
                "FAKE_GH_COUNTER": str(counter_file),
            }
        )
        result = subprocess.run(
            [
                "bash",
                str(WAIT_FOR_PUBLIC_RELEASE),
                "v9.9.9",
                "5",
                mutation_state,
            ],
            check=False,
            capture_output=True,
            text=True,
            env=env,
        )
        count = int(counter_file.read_text(encoding="utf-8").strip())
        return result, count

    def test_release_publication_poll_waits_through_stale_draft_reads(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            result, count = self._poll_public_release(
                Path(raw_root),
                [
                    r"true\tfalse",
                    r"true\tfalse",
                    r"true\tfalse",
                    r"true\tfalse",
                    r"false\tfalse",
                ],
            )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "false\tfalse")
        self.assertEqual(count, 5)

    def test_release_publication_poll_keeps_stale_non_public_reads_ambiguous_after_mutation(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            result, count = self._poll_public_release(
                Path(raw_root),
                [r"true\tfalse"] * 5,
            )
        self.assertEqual(result.returncode, 87)
        self.assertEqual(result.stdout.strip(), "true\tfalse")
        self.assertEqual(count, 5)

    def test_release_publication_poll_confirms_non_public_before_mutation(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            result, count = self._poll_public_release(
                Path(raw_root),
                [r"true\tfalse"] * 5,
                mutation_state="not-attempted",
            )
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout.strip(), "true\tfalse")
        self.assertEqual(count, 5)

    def test_release_publication_poll_keeps_api_failure_ambiguous(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            result, count = self._poll_public_release(
                Path(raw_root),
                ["FAIL"] * 5,
            )
        self.assertEqual(result.returncode, 87)
        self.assertEqual(result.stdout, "")
        self.assertEqual(count, 5)

    def test_release_publication_poll_keeps_malformed_state_ambiguous(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            result, count = self._poll_public_release(
                Path(raw_root),
                ["unexpected-state"] * 5,
                mutation_state="not-attempted",
            )
        self.assertEqual(result.returncode, 87)
        self.assertEqual(result.stdout, "")
        self.assertEqual(count, 5)

    def test_release_workflow_peels_an_annotated_tag_before_main_comparison(
        self,
    ) -> None:
        workflow = (SCRIPT.parents[1] / ".github/workflows/release.yml").read_text(
            encoding="utf-8"
        )
        resolve_tag = 'scripts/verify-release-tag-source.sh "$GITHUB_REF"'
        self.assertIn(resolve_tag, workflow)
        self.assertLess(
            workflow.index(resolve_tag),
            workflow.index('if [ "$release_commit" != "$main_tip" ]'),
        )

    def test_rollback_restores_stable_assets_before_latest_pointer(self) -> None:
        rollback = (
            SCRIPT.parents[1] / ".github" / "workflows" / "oss-rollback.yml"
        ).read_text(encoding="utf-8")
        self.assertIn("group: ssrvpn-public-release", rollback)
        self.assertIn("gh release download", rollback)
        self.assertIn("scripts/check-release-assets.sh", rollback)
        self.assertIn("ANDROID_RELEASE_CERT_SHA256", rollback)
        self.assertIn("scripts/promote-oss-public-channel.sh", rollback)
        self.assertIn("Preserve OSS recovery backup", rollback)
        self.assertNotIn("Download and verify immutable rollback bundle", rollback)

    def test_recovery_backup_artifacts_include_the_hidden_validity_marker(
        self,
    ) -> None:
        for workflow_path in (
            SCRIPT.parents[1] / ".github" / "workflows" / "release.yml",
            SCRIPT.parents[1] / ".github" / "workflows" / "oss-rollback.yml",
        ):
            workflow = workflow_path.read_text(encoding="utf-8")
            start = workflow.index("      - name: Preserve OSS recovery backup\n")
            end = workflow.find("\n      - name:", start + 1)
            step = workflow[start:] if end == -1 else workflow[start:end]
            with self.subTest(workflow=workflow_path.name):
                self.assertIn("include-hidden-files: true", step)
                self.assertIn("OSS_PRESERVE_BACKUP=1", workflow)


class VerifyReleaseTagSourceTest(unittest.TestCase):
    def _git(self, repo: Path, *args: str) -> str:
        result = subprocess.run(
            ["git", *args],
            cwd=repo,
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout.strip()

    def _repository(self, root: Path) -> tuple[Path, str]:
        repo = root / "repo"
        repo.mkdir()
        self._git(repo, "init", "--quiet")
        self._git(repo, "config", "user.name", "Release Test")
        self._git(repo, "config", "user.email", "release-test@example.invalid")
        (repo / "tracked.txt").write_text("release\n", encoding="utf-8")
        self._git(repo, "add", "tracked.txt")
        self._git(repo, "commit", "--quiet", "-m", "release")
        return repo, self._git(repo, "rev-parse", "HEAD")

    def _guard(self, repo: Path, tag: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(TAG_SOURCE_GUARD), f"refs/tags/{tag}"],
            cwd=repo,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_annotated_tag_resolves_to_its_peeled_commit(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            repo, commit = self._repository(Path(raw_root))
            self._git(repo, "tag", "-a", "v1.0.0", "-m", "Release v1.0.0")

            result = self._guard(repo, "v1.0.0")

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), commit)

    def test_lightweight_tag_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as raw_root:
            repo, _ = self._repository(Path(raw_root))
            self._git(repo, "tag", "v1.0.0")

            result = self._guard(repo, "v1.0.0")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("annotated tag", result.stderr)


if __name__ == "__main__":
    unittest.main()
