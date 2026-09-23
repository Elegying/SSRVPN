import json
import itertools
import os
import subprocess
import tempfile
import textwrap
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / ".github" / "workflows" / "ci.yml"
POLICY = ROOT / ".github" / "main-branch-protection.json"


def job(workflow: str, name: str, next_name: str = "") -> str:
    start = workflow.index(f"  {name}:\n")
    end = workflow.index(f"  {next_name}:\n", start) if next_name else len(workflow)
    return workflow[start:end]


class CiDocsScopeTest(unittest.TestCase):
    REQUIRED_CONTEXTS = (
        "Full-history secret scan",
        "Dependency review",
        "CodeQL (Actions)",
        "Prepare verified core assets",
        "macOS native unit tests",
        "Workspace checks",
        "Android",
        "macOS",
        "Windows",
    )

    def test_protected_context_names_remain_exactly_unchanged(self) -> None:
        policy = json.loads(POLICY.read_text(encoding="utf-8"))
        contexts = tuple(
            check["context"]
            for check in policy["required_status_checks"]["checks"]
        )

        self.assertEqual(contexts, self.REQUIRED_CONTEXTS)

    def test_workflow_uses_a_job_classifier_instead_of_path_filtering(self) -> None:
        workflow = CI.read_text(encoding="utf-8")
        trigger = workflow[: workflow.index("permissions:\n")]
        changes = job(workflow, "changes", "secret-scan")

        self.assertNotIn("paths:", trigger)
        self.assertNotIn("paths-ignore:", trigger)
        self.assertIn("platform_required: ${{ steps.scope.outputs.platform_required }}", changes)
        self.assertIn("python3 scripts/classify-ci-scope.py", changes)

    def test_docs_only_keeps_matrix_contexts_but_avoids_macos_runner(self) -> None:
        workflow = CI.read_text(encoding="utf-8")
        matrix = job(workflow, "flutter-app", "windows-policy-tests")

        self.assertIn("    name: ${{ matrix.name }}\n", matrix)
        self.assertIn("    needs: [changes, core-assets, secret-scan]\n", matrix)
        self.assertIn(
            "runs-on: ${{ needs.changes.outputs.platform_required == 'true' && matrix.os || 'ubuntu-latest' }}",
            matrix,
        )
        self.assertIn("Skip platform build for documentation-only changes", matrix)
        self.assertIn("Reject invalid CI scope", matrix)
        self.assertGreaterEqual(
            matrix.count("needs.changes.outputs.platform_required == 'true'"),
            14,
        )

    def test_docs_skip_heavy_workspace_steps_and_keep_privacy_checks(self) -> None:
        workflow = CI.read_text()
        shared = job(workflow, "shared", "core-assets")
        for step in shared.split("      - ")[1:]:
            if "actions/checkout@" in step:
                continue
            if "Validate documentation-only change" in step:
                self.assertIn("platform_required == 'false'", step)
                self.assertIn("scripts.test_third_party_licenses", step)
                self.assertIn("check-doc-consistency.sh", step)
                self.assertIn("scripts.test_doc_consistency", step)
            else:
                self.assertIn("platform_required == 'true'", step)
        core = job(workflow, "core-assets", "macos-native")
        self.assertIn("&& 'macos-15' || 'ubuntu-latest'", core)
        self.assertIn('case "$SCOPE" in', core)
        self.assertIn('*) exit 1 ;;', core)
        for step in core.split("      - ")[1:]:
            if "bootstrap-core-assets.sh" in step or "uses:" in step:
                self.assertIn("platform_required == 'true'", step)

    def test_core_gate_rejects_failed_preflight_and_invalid_scope(self) -> None:
        core = job(CI.read_text(), "core-assets", "macos-native")
        guard = core.split("        run: |\n", 1)[1].split("\n      - ", 1)[0]
        preflight = core.split("        run: ", 1)[1].splitlines()[0]
        script = "set -e\n" + preflight + "\n" + textwrap.dedent(guard)
        for scope, result, succeeds in (
            ("false", "success", True), ("true", "success", True),
            ("", "success", False), ("unknown", "success", False),
            ("false", "failure", False), ("false", "skipped", False),
            ("true", "cancelled", False),
        ):
            with self.subTest(scope=scope, result=result):
                completed = subprocess.run(
                    ["bash", "-c", script],
                    env=dict(os.environ, SCOPE=scope, PREFLIGHT_RESULT=result),
                    capture_output=True,
                )
                self.assertEqual(completed.returncode == 0, succeeds)

    def test_native_and_windows_heavy_jobs_are_scope_gated(self) -> None:
        workflow = CI.read_text(encoding="utf-8")
        native = job(workflow, "macos-native", "flutter-app")
        policy = job(workflow, "windows-policy-tests", "windows-build")
        build = job(workflow, "windows-build", "windows")

        for child in (native, policy, build):
            with self.subTest(job=child.splitlines()[0].strip()):
                self.assertIn("needs.changes.outputs.platform_required == 'true'", child)
                self.assertIn("changes", child.split("    steps:\n", 1)[0])

    def test_windows_required_context_accepts_only_the_expected_child_state(self) -> None:
        workflow = CI.read_text(encoding="utf-8")
        aggregate = job(workflow, "windows")

        self.assertIn("    needs: [changes, windows-policy-tests, windows-tests, windows-build]\n", aggregate)
        self.assertIn("SCOPE: ${{ needs.changes.outputs.platform_required }}", aggregate)
        self.assertIn('if [ "$SCOPE" = true ]; then', aggregate)
        self.assertIn('if [ "$SCOPE" = false ]; then', aggregate)
        self.assertIn('"$POLICY_RESULT" != skipped', aggregate)
        self.assertIn('"$BUILD_RESULT" != skipped', aggregate)
        self.assertIn("Invalid CI scope classification", aggregate)

    def test_windows_gate_executes_fail_closed_for_all_child_results(self) -> None:
        aggregate = job(CI.read_text(), "windows")
        script = textwrap.dedent(aggregate.split("        run: |\n", 1)[1])
        for scope in ("true", "false", "invalid"):
            for results in itertools.product(("success", "failure", "skipped", "cancelled"), repeat=3):
                expected = (scope == "true" and results == ("success",) * 3) or (
                    scope == "false" and results == ("skipped",) * 3)
                env = dict(os.environ, SCOPE=scope, POLICY_RESULT=results[0],
                           TEST_RESULT=results[1], BUILD_RESULT=results[2])
                result = subprocess.run(["bash", "-c", script], env=env, capture_output=True)
                self.assertEqual(result.returncode == 0, expected, (scope, results))

    def test_core_cache_never_bypasses_bootstrap_verification(self) -> None:
        core = job(CI.read_text(), "core-assets", "macos-native")
        cache = core.split("      - name: Cache verified core assets", 1)[1].split("\n      - ", 1)[0]
        self.assertNotIn("restore-keys", cache)
        for dependency in ("native/proxy_traffic/**", "libgojni-source.txt", "AtlasCore-source.txt",
                           "mihomo-source.txt", "GEOIP_SOURCE.txt", "build-core-asset.py",
                           "build-android-core.sh", "build-desktop-core.sh", "core-traffic-source.py",
                           "bootstrap-core-assets.sh", "verify-core-assets.sh", "verify_android_core_*.py"):
            self.assertIn(dependency, cache)
        bootstrap = core.split("run: bash scripts/bootstrap-core-assets.sh", 1)[0].rsplit("      - ", 1)[1]
        self.assertNotIn("cache-hit", bootstrap)
        source = (ROOT / "scripts/bootstrap-core-assets.sh").read_text()
        self.assertTrue(source.rstrip().endswith("bash scripts/verify-core-assets.sh"))

    def test_dual_stack_probes_are_required_and_fail_closed(self) -> None:
        probes = ['scripts/check-core-dual-stack.py', 'scripts/check-core-dual-stack-protocols.py']
        for workflow_file in (CI, ROOT / '.github/workflows/release.yml'):
            workflow = workflow_file.read_text()
            step = workflow.split('      - name: Verify real-core dual-stack forwarding\n', 1)[1].split('\n      - ', 1)[0]
            self.assertNotIn('continue-on-error', step)
            if workflow_file == CI:
                self.assertIn("platform_required == 'true' && matrix.directory == 'SSRVPN_MacOS'", step)
            else:
                self.assertNotIn('if:', step)
            script = textwrap.dedent(step.split('        run: |\n', 1)[1])
            for probe in probes:
                self.assertIn('python3 ' + probe, script)
            with tempfile.TemporaryDirectory() as directory:
                trace = Path(directory) / 'trace'
                stub = 'python3() { echo "$*" >> "$TRACE"; if [ "$*" = "$FAIL_PROBE" ]; then return 7; fi; }\n'
                for fail in ('', *probes):
                    with self.subTest(workflow=workflow_file.name, fail=fail):
                        if trace.exists():
                            trace.unlink()
                        result = subprocess.run(['bash', '-e', '-o', 'pipefail', '-c', stub + script],
                                                env=dict(os.environ, TRACE=str(trace), FAIL_PROBE=fail),
                                                capture_output=True)
                        self.assertEqual(result.returncode, 7 if fail else 0, result.stderr)
                        self.assertEqual(trace.read_text().splitlines(), probes[:1] if fail == probes[0] else probes)


if __name__ == "__main__":
    unittest.main()
