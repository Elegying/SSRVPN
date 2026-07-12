from __future__ import annotations

import subprocess
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("run-command-with-timeout.py")


class RunCommandWithTimeoutTest(unittest.TestCase):
    def test_forwards_stdin_and_exit_status(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "2",
                sys.executable,
                "-c",
                "import sys; sys.stdout.buffer.write(sys.stdin.buffer.read())",
            ],
            input=b"finder-script",
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"finder-script")

    def test_terminates_a_hung_command(self) -> None:
        process = subprocess.Popen(
            [
                sys.executable,
                str(SCRIPT),
                "0.05",
                sys.executable,
                "-c",
                "import time; time.sleep(60)",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            returncode = process.wait(timeout=2)
            stderr = process.stderr.read() if process.stderr else ""
        finally:
            if process.stdin:
                process.stdin.close()
            if process.poll() is None:
                process.kill()
                process.wait()
            if process.stdout:
                process.stdout.close()
            if process.stderr:
                process.stderr.close()
        self.assertEqual(returncode, 124)
        self.assertIn("timed out", stderr)

    def test_accepts_piped_stdin(self) -> None:
        result = subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                "2",
                sys.executable,
                "-c",
                "import sys; print(sys.stdin.read())",
            ],
            input="finder-script",
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "finder-script")


if __name__ == "__main__":
    unittest.main()
