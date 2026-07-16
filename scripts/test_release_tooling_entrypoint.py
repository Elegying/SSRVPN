import shlex
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def listed_python_tests(entrypoint: str) -> list[str]:
    commands: list[str] = []
    current = ""
    for raw_line in entrypoint.splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        continued = stripped.endswith("\\")
        fragment = stripped[:-1].rstrip() if continued else stripped
        current = f"{current} {fragment}".strip()
        if not continued:
            commands.append(current)
            current = ""
    if current:
        commands.append(current)

    invocations = [
        shlex.split(command, comments=True)
        for command in commands
    ]
    invocation = next(
        (
            tokens
            for tokens in invocations
            if tokens[:3] == ["python3", "-m", "unittest"]
        ),
        [],
    )
    return sorted(
        Path(token).name
        for token in invocation[3:]
        if token.startswith("scripts/test_") and token.endswith(".py")
    )


class ReleaseToolingEntrypointTest(unittest.TestCase):
    def test_one_entrypoint_owns_the_complete_python_test_list(self) -> None:
        entrypoint_path = ROOT / "scripts" / "test-release-tooling.sh"
        self.assertTrue(entrypoint_path.is_file())
        entrypoint = entrypoint_path.read_text(encoding="utf-8")

        expected_tests = sorted(
            path.name for path in (ROOT / "scripts").glob("test_*.py")
        )
        self.assertEqual(listed_python_tests(entrypoint), expected_tests)

        for path in (
            ROOT / "scripts" / "verify-all.sh",
            ROOT / ".github" / "workflows" / "ci.yml",
            ROOT / ".github" / "workflows" / "release.yml",
        ):
            content = path.read_text(encoding="utf-8")
            with self.subTest(caller=path.name):
                self.assertIn("scripts/test-release-tooling.sh", content)
                self.assertNotIn("python3 -m unittest scripts/test_", content)

    def test_commented_test_name_does_not_count_as_an_invocation(self) -> None:
        entrypoint = """\
python3 -m unittest \\
  scripts/test_real.py  # scripts/test_inline_decoy.py
# scripts/test_decoy.py
"""
        self.assertEqual(listed_python_tests(entrypoint), ["test_real.py"])

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
