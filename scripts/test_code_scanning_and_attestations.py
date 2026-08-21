import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / ".github" / "workflows" / "ci.yml"
RELEASE = ROOT / ".github" / "workflows" / "release.yml"

CODEQL_SHA = "988661ebb5e81487b3fb31b2185d2856c0a10679"
ATTEST_SHA = "1e69f48acb82d1966a394da916b4c1698aa569d6"


class CodeScanningAndAttestationWorkflowTest(unittest.TestCase):
    def test_ci_scans_supported_native_and_workflow_languages(self) -> None:
        workflow = CI.read_text(encoding="utf-8")

        self.assertIn("security-events: write", workflow)
        self.assertIn("codeql_language: java-kotlin", workflow)
        self.assertIn("languages: c-cpp", workflow)
        self.assertNotIn("codeql_language: swift", workflow)
        self.assertIn("languages: ${{ matrix.codeql_language }}", workflow)
        self.assertIn("build-mode: ${{ matrix.codeql_build_mode }}", workflow)
        self.assertEqual(workflow.count("codeql_build_mode: manual"), 1)
        self.assertIn("build-mode: manual", workflow)
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

    def test_ci_keeps_macos_build_outside_codeql(self) -> None:
        workflow = CI.read_text(encoding="utf-8")
        platform_job = workflow[workflow.index("  flutter-app:\n") :]

        self.assertNotIn("codeql_language: swift", platform_job)
        self.assertNotIn("Prepare macOS dependencies before CodeQL", platform_job)
        self.assertNotIn("Build macOS native target for CodeQL", platform_job)
        self.assertEqual(
            platform_job.count("if: matrix.directory != 'SSRVPN_MacOS'"), 2
        )
        self.assertIn("Build macOS app", platform_job)
        self.assertIn("flutter build macos --debug", platform_job)

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
