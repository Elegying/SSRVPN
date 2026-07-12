import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("verify-release-transition.py")
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
        self.assertIn(
            "distributionSha256Sum="
            "bd71102213493060956ec229d946beee57158dbd89d0e62b91bca0fa2c5f3531",
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
        self.assertGreaterEqual(workflow.count("flutter test --coverage"), 4)
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
        retry_reuse = workflow.index("Reuse an existing GitHub release on retry")
        self.assertLess(validate, retry_reuse)
        self.assertLess(retry_reuse, github_release)
        self.assertIn("scripts/reuse-github-release-assets.sh", workflow)
        self.assertIn("steps.existing_release.outputs.exists != 'true'", workflow)
        oss_publish = workflow.index("Publish immutable release to OSS")
        github_finalize = workflow.index("Finalize GitHub Release")
        self.assertLess(github_release, oss_publish)
        self.assertLess(oss_publish, github_finalize)
        public_promote = workflow.index("Promote OSS public channel")
        self.assertLess(github_finalize, public_promote)
        self.assertIn("scripts/promote-oss-public-channel.sh", workflow)
        self.assertIn("prerelease: false", workflow)
        self.assertIn("--json isPrerelease", workflow)
        self.assertIn("Preserve OSS recovery backup", workflow)

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


if __name__ == "__main__":
    unittest.main()
