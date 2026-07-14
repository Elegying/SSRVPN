import hashlib
import json
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "promote-oss-public-channel.sh"
FILES = (
    "SSRVPN.apk",
    "SSRVPN.apk.sha256",
    "SSRVPN.dmg",
    "SSRVPN.dmg.sha256",
    "SSRVPN_Setup.exe",
    "SSRVPN_Setup.exe.sha256",
    "SSRVPN.zip",
    "SSRVPN.zip.sha256",
)


class PromoteOssPublicChannelTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.objects = self.root / "objects"
        self.source = self.root / "source"
        self.bin = self.root / "bin"
        self.objects.mkdir()
        self.source.mkdir()
        self.bin.mkdir()
        self._write_fake_tools()
        self.old = self._write_channel(self.objects / "ssrvpn", b"old")
        self.new = self._write_channel(self.source, b"new")
        self.manifest = self.source / "latest.json"
        self.manifest.write_text(
            json.dumps(
                {
                    "version": "9.9.9",
                    "assets": [
                        {
                            "name": name,
                            "sha256": hashlib.sha256(
                                (self.source / name).read_bytes()
                            ).hexdigest(),
                        }
                        for name in (
                            "SSRVPN.apk",
                            "SSRVPN.dmg",
                            "SSRVPN_Setup.exe",
                            "SSRVPN.zip",
                        )
                    ],
                }
            ),
            encoding="utf-8",
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_success_promotes_every_asset_and_pointer(self) -> None:
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in FILES:
            self.assertEqual(
                (self.objects / "ssrvpn" / "downloads" / name).read_bytes(),
                (self.source / name).read_bytes(),
            )
        self.assertEqual(
            (self.objects / "ssrvpn" / "latest.json").read_bytes(),
            self.manifest.read_bytes(),
        )

    def test_preserved_backup_can_restore_after_later_publish_failure(self) -> None:
        backup = self.root / "transaction-backup"
        result = self._run(backup=backup, preserve_backup=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(backup.is_dir())

        restore = self._restore(backup)
        self.assertEqual(restore.returncode, 0, restore.stderr)
        self.assertFalse(backup.exists())
        for name in FILES:
            self.assertEqual(
                (self.objects / "ssrvpn" / "downloads" / name).read_bytes(),
                self.old[name],
            )
        self.assertEqual(
            (self.objects / "ssrvpn" / "latest.json").read_bytes(),
            self.old["latest.json"],
        )

    def test_failure_restores_all_previous_objects(self) -> None:
        result = self._run(fail_on="SSRVPN.dmg")
        self.assertNotEqual(result.returncode, 0)
        for name in FILES:
            self.assertEqual(
                (self.objects / "ssrvpn" / "downloads" / name).read_bytes(),
                self.old[name],
            )
        self.assertEqual(
            (self.objects / "ssrvpn" / "latest.json").read_bytes(),
            self.old["latest.json"],
        )

    def test_backup_read_failure_never_mutates_the_public_channel(self) -> None:
        result = self._run(backup_fail_on="SSRVPN.dmg")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot back up current OSS object", result.stderr)
        for name in FILES:
            self.assertEqual(
                (self.objects / "ssrvpn" / "downloads" / name).read_bytes(),
                self.old[name],
            )
        self.assertEqual(
            (self.objects / "ssrvpn" / "latest.json").read_bytes(),
            self.old["latest.json"],
        )
        self.assertEqual(list(self.root.glob("ssrvpn-oss-backup.*")), [])

    def test_restore_failure_is_reported_instead_of_silently_succeeding(self) -> None:
        result = self._run(
            fail_on="SSRVPN.dmg",
            restore_fail_on="SSRVPN.apk",
        )
        self.assertEqual(result.returncode, 86)
        self.assertIn("recovery is incomplete", result.stderr)
        self.assertNotEqual(
            (self.objects / "ssrvpn" / "downloads" / "SSRVPN.apk").read_bytes(),
            self.old["SSRVPN.apk"],
        )

    def _run(
        self,
        fail_on: str = "",
        restore_fail_on: str = "",
        backup_fail_on: str = "",
        backup: Optional[Path] = None,
        preserve_backup: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "OSS_BUCKET": "bucket",
                "OSS_ENDPOINT": "example.invalid",
                "OSS_PREFIX": "ssrvpn",
                "OSSUTIL_BIN": str(self.bin / "ossutil"),
                "CURL_BIN": str(self.bin / "curl"),
                "FAKE_OSS_ROOT": str(self.objects),
                "FAKE_FAIL_ON": fail_on,
                "FAKE_RESTORE_FAIL_ON": restore_fail_on,
                "FAKE_BACKUP_FAIL_ON": backup_fail_on,
                "FAKE_NEW_SOURCE": str(self.source),
                "RUNNER_TEMP": str(self.root),
                "OSS_PRESERVE_BACKUP": "1" if preserve_backup else "0",
            }
        )
        if backup is not None:
            env["OSS_BACKUP_DIR"] = str(backup)
        return subprocess.run(
            ["bash", str(SCRIPT), str(self.source), str(self.manifest)],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )

    def _restore(self, backup: Path) -> subprocess.CompletedProcess[str]:
        env = os.environ.copy()
        env.update(
            {
                "OSS_BUCKET": "bucket",
                "OSS_ENDPOINT": "example.invalid",
                "OSS_PREFIX": "ssrvpn",
                "OSSUTIL_BIN": str(self.bin / "ossutil"),
                "CURL_BIN": str(self.bin / "curl"),
                "FAKE_OSS_ROOT": str(self.objects),
                "FAKE_NEW_SOURCE": str(self.source),
            }
        )
        return subprocess.run(
            ["bash", str(SCRIPT), "--restore", str(backup)],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )

    def _write_channel(self, root: Path, prefix: bytes) -> dict[str, bytes]:
        downloads = root / "downloads" if root != self.source else root
        downloads.mkdir(parents=True, exist_ok=True)
        values: dict[str, bytes] = {}
        for name in ("SSRVPN.apk", "SSRVPN.dmg", "SSRVPN_Setup.exe", "SSRVPN.zip"):
            payload = prefix + b"-" + name.encode()
            (downloads / name).write_bytes(payload)
            digest = hashlib.sha256(payload).hexdigest().encode()
            checksum = digest + b"  " + name.encode() + b"\n"
            (downloads / f"{name}.sha256").write_bytes(checksum)
            values[name] = payload
            values[f"{name}.sha256"] = checksum
        latest = prefix + b"-latest"
        if root == self.source:
            return values
        (root / "latest.json").write_bytes(latest)
        values["latest.json"] = latest
        return values

    def _write_fake_tools(self) -> None:
        ossutil = self.bin / "ossutil"
        ossutil.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import os, pathlib, shutil, sys
                root = pathlib.Path(os.environ['FAKE_OSS_ROOT'])
                command = sys.argv[1]
                def object_path(value):
                    return root / value.split('/', 3)[3]
                if command == 'cp':
                    source, destination = sys.argv[2], sys.argv[3]
                    if (os.environ.get('FAKE_FAIL_ON') == pathlib.Path(destination).name
                            and source.startswith(os.environ.get('FAKE_NEW_SOURCE', '') + os.sep)):
                        raise SystemExit(9)
                    if (os.environ.get('FAKE_RESTORE_FAIL_ON') == pathlib.Path(destination).name
                            and not source.startswith(os.environ.get('FAKE_NEW_SOURCE', '') + os.sep)):
                        raise SystemExit(10)
                    target = object_path(destination)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, target)
                elif command == 'rm':
                    object_path(sys.argv[2]).unlink(missing_ok=True)
                else:
                    raise SystemExit(2)
                """
            ),
            encoding="utf-8",
        )
        curl = self.bin / "curl"
        curl.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env python3
                import os, pathlib, shutil, sys
                root = pathlib.Path(os.environ['FAKE_OSS_ROOT'])
                args = sys.argv[1:]
                destination = pathlib.Path(args[args.index('-o') + 1])
                url = next(value for value in reversed(args) if value.startswith('https://'))
                path = root / url.split('/', 3)[3]
                if os.environ.get('FAKE_BACKUP_FAIL_ON') == destination.name:
                    print('500', end='')
                    raise SystemExit(0)
                if not path.is_file():
                    print('404', end='')
                    raise SystemExit(0)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, destination)
                print('200', end='')
                """
            ),
            encoding="utf-8",
        )
        for path in (ossutil, curl):
            path.chmod(path.stat().st_mode | stat.S_IXUSR)


if __name__ == "__main__":
    unittest.main()
