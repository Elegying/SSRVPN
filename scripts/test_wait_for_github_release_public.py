from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/wait-for-github-release-public.sh"


class WaitForGithubReleasePublicTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.log = self.root / "gh.log"
        gh = self.root / "gh"
        gh.write_text(
            """#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_GH_LOG"
if [ "$1" = api ]; then
  if [ "$FAKE_GH_MODE" = exact-public ]; then
    printf '42\tv3.2.0\tfalse\tfalse\n'
    exit 0
  fi
  echo 'gh: Not Found (HTTP 404)' >&2
  exit 1
fi
if [ "$1" = release ] && [ "$FAKE_GH_MODE" = tag-public ]; then
  printf 'false\tfalse\n'
  exit 0
fi
exit 1
""",
            encoding="utf-8",
        )
        gh.chmod(0o755)

    def tearDown(self) -> None:
        self.temp.cleanup()

    def _run(self, mode: str, expected_id: str = "") -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "PATH": f"{self.root}:{env['PATH']}",
                "FAKE_GH_LOG": str(self.log),
                "FAKE_GH_MODE": mode,
                "GITHUB_REPOSITORY": "Elegying/SSRVPN",
            }
        )
        return subprocess.run(
            ["bash", str(SCRIPT), "v3.2.0", "1", "attempted", expected_id],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )

    def test_exact_release_id_becomes_public(self) -> None:
        result = self._run("exact-public", "42")

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text(encoding="utf-8")
        self.assertIn("repos/Elegying/SSRVPN/releases/42", calls)
        self.assertNotIn("release view", calls)

    def test_same_tag_replacement_cannot_satisfy_an_exact_id_poll(self) -> None:
        result = self._run("tag-public", "42")

        self.assertEqual(result.returncode, 87)
        calls = self.log.read_text(encoding="utf-8")
        self.assertIn("repos/Elegying/SSRVPN/releases/42", calls)
        self.assertNotIn("release view", calls)

    def test_new_release_keeps_the_tag_polling_path(self) -> None:
        result = self._run("tag-public")

        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.log.read_text(encoding="utf-8")
        self.assertIn("release view v3.2.0", calls)


if __name__ == "__main__":
    unittest.main()
