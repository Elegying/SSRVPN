"""Replay the real source guard with a non-UTF-8 default text encoding."""

import os
from pathlib import Path
import subprocess
import sys
import unittest


ROOT = Path(__file__).resolve().parents[1]


class ClashServiceBoundaryEncodingTests(unittest.TestCase):
    def test_guard_reads_utf8_sources_with_legacy_windows_locale(self):
        guard = (ROOT / "scripts/check-clash-service-boundaries.sh").read_text(
            encoding="utf-8"
        )
        source = guard.split("python3 - <<'PY'\n", 1)[1].rsplit("\nPY", 1)[0]
        # Exercise production reads on every host, including UTF-8-default CI.
        # Explicit encodings retain their normal behavior; omitted ones emulate
        # the Chinese Windows locale that previously broke the guard.
        bootstrap = """
from pathlib import Path
original = Path.read_text
def legacy_read(self, encoding=None, errors=None):
    return original(self, encoding=encoding or 'cp936', errors=errors)
Path.read_text = legacy_read
"""
        result = subprocess.run(
            [sys.executable, "-c", bootstrap + source],
            cwd=ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8",
            env={**os.environ, "PYTHONIOENCODING": "utf-8"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("responsibility boundaries passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
