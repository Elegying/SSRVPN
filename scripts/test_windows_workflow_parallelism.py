import unittest
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / ".github" / "workflows" / "ci.yml"
RELEASE = ROOT / ".github" / "workflows" / "release.yml"
POLICY_RUNNER = ROOT / "scripts" / "test_windows_policy.ps1"


def job(workflow: str, name: str, next_name: Optional[str] = None) -> str:
    start = workflow.index(f"  {name}:\n")
    end = workflow.index(f"  {next_name}:\n", start) if next_name else len(workflow)
    return workflow[start:end]


class WindowsWorkflowParallelismTest(unittest.TestCase):
    def test_ci_parallelizes_policy_and_build_behind_stable_windows_gate(self) -> None:
        workflow = CI.read_text(encoding="utf-8")
        platform = job(workflow, "flutter-app", "windows-policy-tests")
        policy = job(workflow, "windows-policy-tests", "windows-build")
        build = job(workflow, "windows-build", "windows")
        aggregate = job(workflow, "windows")

        self.assertNotIn("          - name: Windows\n", platform)
        self.assertIn("    needs: [changes, secret-scan]\n", policy)
        self.assertIn("    needs: [changes, core-assets, secret-scan]\n", build)
        for child in (policy, build):
            self.assertIn("    runs-on: windows-latest\n", child)

        self.assertIn("scripts\\test_windows_policy.ps1", policy)
        self.assertNotIn("test_windows_policy.ps1", build)
        for independent_test in (
            "test_windows_powershell51_compatibility.ps1",
            "test_windows_installer_runtime.ps1",
            "test_windows_program_files_transaction.ps1",
            "test_windows_package_payload_guard.ps1",
            "installer\\stop_ssrvpn_processes.ps1",
        ):
            with self.subTest(independent_test=independent_test):
                self.assertNotIn(independent_test, build)

        self.assert_windows_build_gates(build)
        self.assertIn("    name: Windows\n", aggregate)
        self.assertIn("    if: always()\n", aggregate)
        self.assertIn(
            "    needs: [changes, windows-policy-tests, windows-build]\n",
            aggregate,
        )
        self.assertIn("POLICY_RESULT: ${{ needs.windows-policy-tests.result }}", aggregate)
        self.assertIn("BUILD_RESULT: ${{ needs.windows-build.result }}", aggregate)
        self.assertIn('if [ "$POLICY_RESULT" != success ] ||', aggregate)
        self.assertIn('[ "$BUILD_RESULT" != success ]; then', aggregate)

    def test_release_runs_policy_in_parallel_and_publish_requires_both(self) -> None:
        workflow = RELEASE.read_text(encoding="utf-8")
        policy = job(workflow, "windows-policy-tests", "build-windows")
        build = job(workflow, "build-windows", "publish")
        publish = job(workflow, "publish")

        self.assertIn("    needs: validate-source\n", policy)
        self.assertIn("    needs: [validate-source, prepare-geoip]\n", build)
        self.assertIn("    runs-on: windows-latest\n", policy)
        self.assertIn("    runs-on: windows-latest\n", build)
        self.assertIn("scripts\\test_windows_policy.ps1", policy)
        self.assertNotIn("test_windows_policy.ps1", build)
        self.assert_windows_build_gates(build, release=True)

        header = publish[: publish.index("    steps:\n")]
        self.assertIn("windows-policy-tests", header)
        self.assertIn("build-windows", header)

    def test_single_policy_runner_owns_all_independent_windows_tests(self) -> None:
        self.assertTrue(POLICY_RUNNER.is_file())
        source = POLICY_RUNNER.read_text(encoding="ascii")

        for child in (
            "test_windows_powershell51_compatibility.ps1",
            "test_windows_installer_runtime.ps1",
            "test_windows_program_files_transaction.ps1",
            "test_windows_package_payload_guard.ps1",
            "SSRVPN_Windows\\installer\\stop_ssrvpn_processes.ps1",
        ):
            with self.subTest(child=child):
                self.assertEqual(source.count(child), 1)

        for argument in (
            "-InstalledAppPath",
            "-InstalledLauncherPath",
            "-InstalledCorePath",
            "-InstalledCorePidPath",
        ):
            self.assertIn(argument, source)
        self.assertIn("powershell.exe", source)
        self.assertIn("$LASTEXITCODE", source)
        self.assertIn("throw", source)

    def assert_windows_build_gates(self, build: str, release: bool = False) -> None:
        required = (
            "scripts/run-flutter-coverage.sh SSRVPN_Windows",
            "scripts/check-coverage-thresholds.sh SSRVPN_Windows",
            "test_windows_native_proxy_recovery.ps1",
            "tool\\package_windows.ps1",
            "tool\\build_installer.ps1",
            "test_windows_installer_package.ps1",
            "smoke-release-artifacts.sh --allow-missing",
            "Upload Windows installer smoke logs",
        )
        for expected in required:
            with self.subTest(expected=expected, release=release):
                self.assertIn(expected, build)
        if release:
            self.assertIn("actions/attest@", build)
            self.assertIn("name: windows\n", build)
        else:
            self.assertIn("languages: c-cpp", build)
            self.assertIn("build-mode: manual", build)
            self.assertIn("name: windows-installer-pr\n", build)
            self.assertIn("coverage-SSRVPN_Windows", build)


if __name__ == "__main__":
    unittest.main()
