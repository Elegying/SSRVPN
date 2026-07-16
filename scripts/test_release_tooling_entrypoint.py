import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class ReleaseToolingEntrypointTest(unittest.TestCase):
    def test_one_entrypoint_owns_the_complete_python_test_list(self) -> None:
        entrypoint_path = ROOT / "scripts" / "test-release-tooling.sh"
        self.assertTrue(entrypoint_path.is_file())
        entrypoint = entrypoint_path.read_text(encoding="utf-8")

        expected_tests = sorted(
            path.name for path in (ROOT / "scripts").glob("test_*.py")
        )
        for test_name in expected_tests:
            with self.subTest(test=test_name):
                self.assertEqual(entrypoint.count(f"scripts/{test_name}"), 1)

        for path in (
            ROOT / "scripts" / "verify-all.sh",
            ROOT / ".github" / "workflows" / "ci.yml",
            ROOT / ".github" / "workflows" / "release.yml",
        ):
            content = path.read_text(encoding="utf-8")
            with self.subTest(caller=path.name):
                self.assertIn("scripts/test-release-tooling.sh", content)
                self.assertNotIn("python3 -m unittest scripts/test_", content)

    def test_publish_job_requires_the_release_environment(self) -> None:
        workflow = (
            ROOT / ".github" / "workflows" / "release.yml"
        ).read_text(encoding="utf-8")
        publish = workflow[workflow.index("  publish:\n") :]
        self.assertIn("    environment: release\n", publish)
        self.assertLess(
            publish.index("    environment: release\n"),
            publish.index("    steps:\n"),
        )


if __name__ == "__main__":
    unittest.main()
