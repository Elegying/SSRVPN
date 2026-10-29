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
    def test_release_tools_use_lightweight_lane_and_unknown_changes_stay_full(self):
        classifier = load_classifier()
        for path in classifier._RELEASE_TOOLING:
            with self.subTest(path=path):
                self.assertTrue((ROOT / path).is_file())
                self.assertEqual(classifier.classify([path, "CHANGELOG.md"]), "release-tooling")
        for path in [".github/workflows/ci.yml", "scripts/classify-ci-scope.py",
                     "scripts/test-release-tooling.sh", ".github/actions/setup-flutter/action.yml",
                     "SSRVPN_Windows/installer/program_files_transaction.ps1",
                     "scripts/optimize-android-apk.py", "scripts/build-macos-local.sh",
                     "native/proxy_traffic/sources.json", "pubspec.lock", ".fvmrc",
                     "packages/ssrvpn_shared/lib/services/update_service.dart",
                     "scripts/new-release-helper.py", ".github/workflows/maintenance.yml"]:
            with self.subTest(path=path):
                self.assertEqual(classifier.classify([path, "scripts/generate-release-notes.py"]), "full")

    def test_release_workflow_build_surface_is_not_path_allowlisted(self):
        classifier = load_classifier()
        original = (ROOT / ".github/workflows/release.yml").read_text()
        baseline = classifier.release_workflow_surface(original)
        publishing = original.replace("      - name: Generate release notes", "      - name: Generate reviewed release notes")
        self.assertEqual(baseline, classifier.release_workflow_surface(publishing))
        for modified in [original.replace("macos-15", "macos-99"),
                         original.replace("    environment: release", "    environment: unprotected"),
                         original.replace("needs: [validate-source, shared-test, build-android", "needs: [validate-source, build-android"),
                         original.replace("needs: [validate-source, prepare-geoip]", "needs: [validate-source]"),
                         original.replace("run: flutter analyze", "run: echo skipped"),
                         original.replace("run: python3 scripts/generate-release-notes.py --tag \"$GITHUB_REF_NAME\"", "run: echo changed"),
                         original + "\n  unrecognized-build:\n    runs-on: windows-latest\n"]:
            with self.subTest(change=modified[-80:]):
                self.assertNotEqual(baseline, classifier.release_workflow_surface(modified))
        self.assertEqual(classifier.classify([".github/workflows/release.yml"]), "full")
        self.assertEqual(classifier.classify([".github/workflows/release.yml"], release_workflow_safe=True), "release-tooling")
        for invalid in ["", original.replace("  publish:\n", "  changed:\n")]:
            with self.assertRaises(ValueError):
                classifier.release_workflow_surface(invalid)

    def test_real_git_workflow_diff_and_missing_source_fail_closed(self):
        classifier = load_classifier()
        original = (ROOT / ".github/workflows/release.yml").read_text()
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=repository, text=True).strip()
            git("init", "-q")
            git("config", "user.name", "CI Scope Test")
            git("config", "user.email", "scope@example.invalid")
            workflow = repository / ".github/workflows/release.yml"
            workflow.parent.mkdir(parents=True)
            workflow.write_text(original)
            git("add", ".")
            git("commit", "-qm", "base")
            base = git("rev-parse", "HEAD")
            for content, expected in [
                (original.replace("Generate release notes", "Generate reviewed release notes"), "release-tooling"),
                (original.replace("macos-15", "macos-99"), "full"),
                (original.replace("    environment: release", "    environment: unprotected"), "full"),
                (original.replace("needs: [validate-source, shared-test, build-android", "needs: [validate-source, build-android"), "full"),
                (None, "full"),
            ]:
                if content is None:
                    workflow.unlink()
                else:
                    workflow.write_text(content)
                git("add", "-A")
                git("commit", "-qm", "change")
                head = git("rev-parse", "HEAD")
                for event in ["push", "pull_request"]:
                    result = subprocess.run([sys.executable, str(SCRIPT), "--kind", "--event", event,
                                             "--base", base, "--head", head], cwd=repository,
                                            capture_output=True, text=True, check=True)
                    self.assertEqual(result.stdout.strip(), expected, result.stderr)

    def test_kind_mode_manual_dispatch_still_forces_full(self):
        result = subprocess.run([sys.executable, str(SCRIPT), "--kind", "--event", "workflow_dispatch"],
                                text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout.strip(), "full")

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
                ["CHANGELOG.md", "docs/images/ui.png"]
            )
        )

    def test_workbuddy_skill_markdown_can_skip_platform_jobs(self) -> None:
        classifier = load_classifier()

        self.assertFalse(
            classifier.platform_required(
                [".workbuddy-ai/skills/ssrvpn-codebase/SKILL.md"]
            )
        )
        self.assertFalse(
            classifier.platform_required(
                [".workbuddy-ai/skills/ssrvpn-codebase/references/guardrails.md"]
            )
        )
        # Non-markdown under .workbuddy-ai/ still fails closed to full CI.
        self.assertTrue(
            classifier.platform_required(
                [".workbuddy-ai/skills/ssrvpn-codebase/scripts/run.sh"]
            )
        )

    def test_mixed_or_non_documentation_paths_require_platform_jobs(self) -> None:
        classifier = load_classifier()

        for paths in (
            ["README.md", "lib/main.dart"],
            ["docs/GEOIP_SOURCE.txt"],
            ["docs/config.json"],
            ["docs/example.py"],
            ["packages/example/README.md"],
            [".github/workflows/ci.yml"],
            ["scripts/build-macos-local.sh"],
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
