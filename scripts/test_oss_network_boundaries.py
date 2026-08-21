import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]


def _write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def _job(workflow: str, name: str, next_name: Optional[str] = None) -> str:
    start = workflow.index(f"  {name}:\n")
    end = workflow.index(f"  {next_name}:\n", start) if next_name else len(workflow)
    return workflow[start:end]


class OssNetworkBoundariesTest(unittest.TestCase):
    def test_installer_constrains_curl_and_installs_the_verified_binary(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            curl_args = root / "curl-args"

            _write_executable(
                fake_bin / "curl",
                "#!/bin/sh\n"
                "set -eu\n"
                "printf '%s\\n' \"$@\" > \"$FAKE_CURL_ARGS\"\n",
            )
            _write_executable(
                fake_bin / "sha256sum",
                "#!/bin/sh\ncat >/dev/null\n",
            )
            _write_executable(
                fake_bin / "unzip",
                "#!/bin/sh\n"
                "set -eu\n"
                "while [ \"$#\" -gt 0 ]; do\n"
                "  if [ \"$1\" = '-d' ]; then shift; destination=$1; fi\n"
                "  shift\n"
                "done\n"
                "mkdir -p \"$destination/ossutil-2.3.0-linux-amd64\"\n"
                "printf '#!/bin/sh\\n' > "
                "\"$destination/ossutil-2.3.0-linux-amd64/ossutil\"\n"
                "chmod +x \"$destination/ossutil-2.3.0-linux-amd64/ossutil\"\n",
            )

            destination = root / "install"
            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}:{env['PATH']}"
            env["FAKE_CURL_ARGS"] = str(curl_args)
            subprocess.run(
                ["bash", str(ROOT / "scripts/install-ossutil.sh"), str(destination)],
                cwd=ROOT,
                env=env,
                check=True,
                capture_output=True,
                text=True,
            )

            args = curl_args.read_text(encoding="utf-8").splitlines()
            for option, value in (
                ("--proto", "=https"),
                ("--proto-redir", "=https"),
                ("--retry", "3"),
                ("--connect-timeout", "10"),
                ("--max-time", "180"),
                ("--max-filesize", "104857600"),
            ):
                with self.subTest(option=option):
                    index = args.index(option)
                    self.assertEqual(args[index + 1], value)
            self.assertTrue(args[-1].startswith("https://"))
            self.assertTrue((destination / "ossutil").is_file())

    def test_installer_stops_before_verification_when_curl_rejects_download(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            verification_marker = root / "verification-ran"
            unzip_marker = root / "unzip-ran"

            _write_executable(fake_bin / "curl", "#!/bin/sh\nexit 63\n")
            _write_executable(
                fake_bin / "sha256sum",
                f"#!/bin/sh\ntouch {verification_marker!s}\n",
            )
            _write_executable(
                fake_bin / "unzip",
                f"#!/bin/sh\ntouch {unzip_marker!s}\n",
            )

            env = os.environ.copy()
            env["PATH"] = f"{fake_bin}:{env['PATH']}"
            result = subprocess.run(
                [
                    "bash",
                    str(ROOT / "scripts/install-ossutil.sh"),
                    str(root / "install"),
                ],
                cwd=ROOT,
                env=env,
                check=False,
                capture_output=True,
                text=True,
            )

            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(verification_marker.exists())
            self.assertFalse(unzip_marker.exists())
            self.assertFalse((root / "install" / "ossutil").exists())

    def test_maintenance_jobs_have_deadlines_and_health_download_limits(self) -> None:
        workflow = (ROOT / ".github/workflows/maintenance.yml").read_text(
            encoding="utf-8"
        )
        smoke = _job(workflow, "oss-smoke", "oss-rollback")
        rollback = _job(workflow, "oss-rollback")

        self.assertIn("    timeout-minutes: 10\n", smoke)
        self.assertIn("    timeout-minutes: 30\n", rollback)

        health = smoke[smoke.index("      - name: Upload and verify health object\n") :]
        for expected in (
            "--proto '=https'",
            "--proto-redir '=https'",
            "--retry 3",
            "--connect-timeout 10",
            "--max-time 60",
            "--max-filesize 1048576",
        ):
            with self.subTest(expected=expected):
                self.assertIn(expected, health)

        self.assertIn("--proto '=https'", rollback)
        self.assertIn("--proto-redir '=https'", rollback)


if __name__ == "__main__":
    unittest.main()
