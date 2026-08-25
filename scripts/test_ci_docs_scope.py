import json
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

        self.assertIn("    needs: [changes, windows-policy-tests, windows-build]\n", aggregate)
        self.assertIn("SCOPE: ${{ needs.changes.outputs.platform_required }}", aggregate)
        self.assertIn('if [ "$SCOPE" = true ]; then', aggregate)
        self.assertIn('if [ "$SCOPE" = false ]; then', aggregate)
        self.assertIn('"$POLICY_RESULT" != skipped', aggregate)
        self.assertIn('"$BUILD_RESULT" != skipped', aggregate)
        self.assertIn("Invalid CI scope classification", aggregate)


if __name__ == "__main__":
    unittest.main()
