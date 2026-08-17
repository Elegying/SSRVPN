import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / ".github" / "workflows" / "ci.yml"
RELEASE = ROOT / ".github" / "workflows" / "release.yml"

CODEQL_SHA = "988661ebb5e81487b3fb31b2185d2856c0a10679"
ATTEST_SHA = "1e69f48acb82d1966a394da916b4c1698aa569d6"


class CodeScanningAndAttestationWorkflowTest(unittest.TestCase):
    def test_ci_scans_all_supported_native_and_workflow_languages(self) -> None:
        workflow = CI.read_text(encoding="utf-8")

        self.assertIn("security-events: write", workflow)
        for language in ("java-kotlin", "swift", "c-cpp"):
            self.assertIn(f"codeql_language: {language}", workflow)
        self.assertIn("languages: ${{ matrix.codeql_language }}", workflow)
        self.assertIn("build-mode: ${{ matrix.codeql_build_mode }}", workflow)
        self.assertEqual(workflow.count("codeql_build_mode: manual"), 3)
        self.assertNotIn("codeql_build_mode: autobuild", workflow)
        self.assertIn("languages: actions", workflow)
        self.assertIn("build-mode: none", workflow)
        self.assertGreaterEqual(
            workflow.count(f"github/codeql-action/init@{CODEQL_SHA}"),
            2,
        )
        self.assertGreaterEqual(
            workflow.count(f"github/codeql-action/analyze@{CODEQL_SHA}"),
            2,
        )

    def test_ci_prepares_swift_dependencies_before_single_arch_codeql_build(
        self,
    ) -> None:
        workflow = CI.read_text(encoding="utf-8")
        platform_job = workflow[workflow.index("  flutter-app:\n") :]

        self.assertEqual(platform_job.count("codeql_build_mode: manual"), 3)
        self.assertNotIn("codeql_build_mode: autobuild", platform_job)
        self.assertIn("build-mode: ${{ matrix.codeql_build_mode }}", platform_job)
        self.assertIn("Prepare macOS dependencies before CodeQL", platform_job)
        self.assertIn("xcodebuild -resolvePackageDependencies", platform_job)
        self.assertLess(
            platform_job.index("Prepare macOS dependencies before CodeQL"),
            platform_job.index("Initialize CodeQL"),
        )
        self.assertIn("Build macOS native target for CodeQL", platform_job)
        self.assertIn("xcodebuild build", platform_job)
        self.assertIn("-disableAutomaticPackageResolution", platform_job)
        self.assertIn("-destination 'generic/platform=macOS'", platform_job)
        self.assertIn("ARCH=arm64", platform_job)
        self.assertIn("ARCHS=arm64", platform_job)
        self.assertIn("ONLY_ACTIVE_ARCH=NO", platform_job)
        macos_build = platform_job[
            platform_job.index("Build macOS native target for CodeQL") : platform_job.index(
                "Build Windows installer"
            )
        ]
        self.assertNotIn("x86_64", macos_build)
        self.assertGreaterEqual(
            platform_job.count(
                '-derivedDataPath "$RUNNER_TEMP/ssrvpn-codeql-derived-data"'
            ),
            2,
        )
        self.assertLess(
            platform_job.index("Build macOS native target for CodeQL"),
            platform_job.index("Analyze native code"),
        )

    def test_release_attests_exact_public_binaries_before_publication(self) -> None:
        workflow = RELEASE.read_text(encoding="utf-8")

        jobs = (
            ("build-android", "build-macos", "SSRVPN_Android/SSRVPN.apk"),
            ("build-macos", "build-windows", "SSRVPN_MacOS/SSRVPN.dmg"),
            ("build-windows", "publish", "SSRVPN_Windows/SSRVPN_Setup.exe"),
        )
        for current, following, artifact in jobs:
            start = workflow.index(f"  {current}:")
            end = workflow.index(f"  {following}:", start)
            job = workflow[start:end]
            for permission in (
                "id-token: write",
                "attestations: write",
                "artifact-metadata: write",
            ):
                self.assertIn(permission, job)
            self.assertIn(f"actions/attest@{ATTEST_SHA}", job)
            self.assertIn(f"subject-path: {artifact}", job)
            self.assertLess(
                job.index("Generate signed build provenance attestation"),
                job.index("Upload artifacts"),
            )

        self.assertEqual(workflow.count(f"actions/attest@{ATTEST_SHA}"), 3)


if __name__ == "__main__":
    unittest.main()
