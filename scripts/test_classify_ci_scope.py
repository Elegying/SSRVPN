import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "classify-ci-scope.py"


def load_classifier():
    spec = importlib.util.spec_from_file_location("classify_ci_scope", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ClassifyCiScopeTest(unittest.TestCase):
    def run_classifier(
        self,
        event: str,
        *,
        base: str = "",
        head: str = "",
        cwd: Path = ROOT,
    ) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "--event",
                event,
                "--base",
                base,
                "--head",
                head,
            ],
            cwd=cwd,
            text=True,
            capture_output=True,
            check=False,
        )

    def test_only_root_markdown_and_docs_tree_can_skip_platform_jobs(self) -> None:
        classifier = load_classifier()

        self.assertFalse(classifier.platform_required(["README.md"]))
        self.assertFalse(
            classifier.platform_required(
                ["CHANGELOG.md", "docs/GEOIP_SOURCE.txt", "docs/images/ui.png"]
            )
        )

    def test_mixed_or_non_documentation_paths_require_platform_jobs(self) -> None:
        classifier = load_classifier()

        for paths in (
            ["README.md", "lib/main.dart"],
            ["packages/example/README.md"],
            [".github/workflows/ci.yml"],
            ["scripts/prepare-release.sh"],
            [],
        ):
            with self.subTest(paths=paths):
                self.assertTrue(classifier.platform_required(paths))

    def test_workflow_dispatch_and_unknown_events_fail_closed_to_full(self) -> None:
        for event in ("workflow_dispatch", "schedule", ""):
            with self.subTest(event=event):
                result = self.run_classifier(event)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "true")

    def test_missing_or_malformed_revisions_fail_closed_to_full(self) -> None:
        cases = (
            ("pull_request", "", ""),
            ("pull_request", "not-a-sha", "a" * 40),
            ("push", "0" * 40, "a" * 40),
        )
        for event, base, head in cases:
            with self.subTest(event=event, base=base, head=head):
                result = self.run_classifier(event, base=base, head=head)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "true")

    def test_git_failure_fails_closed_to_full(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            result = self.run_classifier(
                "push",
                base="a" * 40,
                head="b" * 40,
                cwd=Path(temporary),
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "true")

    def test_pull_request_diff_classifies_docs_and_code_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
            subprocess.run(
                ["git", "config", "user.name", "CI Scope Test"],
                cwd=repository,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.email", "ci-scope@example.invalid"],
                cwd=repository,
                check=True,
            )
            (repository / "README.md").write_text("base\n", encoding="utf-8")
            subprocess.run(["git", "add", "README.md"], cwd=repository, check=True)
            subprocess.run(["git", "commit", "-qm", "base"], cwd=repository, check=True)
            base = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=repository, text=True
            ).strip()

            (repository / "docs").mkdir()
            (repository / "docs" / "guide.md").write_text("docs\n", encoding="utf-8")
            subprocess.run(["git", "add", "docs/guide.md"], cwd=repository, check=True)
            subprocess.run(["git", "commit", "-qm", "docs"], cwd=repository, check=True)
            docs_head = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=repository, text=True
            ).strip()

            docs = self.run_classifier(
                "pull_request", base=base, head=docs_head, cwd=repository
            )
            self.assertEqual(docs.returncode, 0, docs.stderr)
            self.assertEqual(docs.stdout.strip(), "false")

            (repository / "lib.dart").write_text("void main() {}\n", encoding="utf-8")
            subprocess.run(["git", "add", "lib.dart"], cwd=repository, check=True)
            subprocess.run(["git", "commit", "-qm", "code"], cwd=repository, check=True)
            code_head = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=repository, text=True
            ).strip()

            code = self.run_classifier(
                "pull_request", base=base, head=code_head, cwd=repository
            )
            self.assertEqual(code.returncode, 0, code.stderr)
            self.assertEqual(code.stdout.strip(), "true")

    def test_code_to_docs_rename_still_requires_platform_jobs(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            repository = Path(temporary)
            subprocess.run(["git", "init", "-q"], cwd=repository, check=True)
            subprocess.run(
                ["git", "config", "user.name", "CI Scope Test"],
                cwd=repository,
                check=True,
            )
            subprocess.run(
                ["git", "config", "user.email", "ci-scope@example.invalid"],
                cwd=repository,
                check=True,
            )
            (repository / "source.dart").write_text("void main() {}\n", encoding="utf-8")
            subprocess.run(["git", "add", "source.dart"], cwd=repository, check=True)
            subprocess.run(["git", "commit", "-qm", "base"], cwd=repository, check=True)
            base = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=repository, text=True
            ).strip()

            (repository / "docs").mkdir()
            subprocess.run(
                ["git", "mv", "source.dart", "docs/source.md"],
                cwd=repository,
                check=True,
            )
            subprocess.run(["git", "commit", "-qam", "rename"], cwd=repository, check=True)
            head = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=repository, text=True
            ).strip()

            result = self.run_classifier(
                "pull_request", base=base, head=head, cwd=repository
            )

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "true")


if __name__ == "__main__":
    unittest.main()
