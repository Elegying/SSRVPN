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
PUBLISHED_FILES = (
    "SSRVPN.apk",
    "SSRVPN.apk.sha256",
    "SSRVPN.dmg",
    "SSRVPN.dmg.sha256",
    "SSRVPN_Setup.exe",
    "SSRVPN_Setup.exe.sha256",
)
RETIRED_FILES = (
    "SSRVPN.zip",
    "SSRVPN.zip.sha256",
)
RETIRED_MARKER = (
    b"SSRVPN Windows portable distribution retired; use SSRVPN_Setup.exe.\n"
)
MANAGED_FILES = PUBLISHED_FILES + RETIRED_FILES


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
        for name in PUBLISHED_FILES:
            self.assertEqual(
                (self.objects / "ssrvpn" / "downloads" / name).read_bytes(),
                (self.source / name).read_bytes(),
            )
        for name in RETIRED_FILES:
            self.assertFalse(
                (self.objects / "ssrvpn" / "downloads" / name).exists()
            )
        self.assertEqual(
            (self.objects / "ssrvpn" / "latest.json").read_bytes(),
            self.manifest.read_bytes(),
        )

    def test_success_tolerates_already_absent_retired_aliases(self) -> None:
        for name in RETIRED_FILES:
            (self.objects / "ssrvpn" / "downloads" / name).unlink()

        result = self._run()

        self.assertEqual(result.returncode, 0, result.stderr)
        for name in RETIRED_FILES:
            self.assertFalse(
                (self.objects / "ssrvpn" / "downloads" / name).exists()
            )

    def test_delete_denial_replaces_retired_aliases_with_marker(self) -> None:
        result = self._run(deny_retired_delete=True)

        self.assertEqual(result.returncode, 0, result.stderr)
        for name in RETIRED_FILES:
            self.assertEqual(
                (self.objects / "ssrvpn" / "downloads" / name).read_bytes(),
                RETIRED_MARKER,
            )

    def test_marker_fallback_preserves_transactional_restore(self) -> None:
        backup = self.root / "transaction-backup"
        result = self._run(
            backup=backup,
            preserve_backup=True,
            deny_retired_delete=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        restore = self._restore(backup)
        self.assertEqual(restore.returncode, 0, restore.stderr)
        for name in RETIRED_FILES:
            self.assertEqual(
                (self.objects / "ssrvpn" / "downloads" / name).read_bytes(),
                self.old[name],
            )

    def test_preserved_backup_can_restore_after_later_publish_failure(self) -> None:
        backup = self.root / "transaction-backup"
        result = self._run(backup=backup, preserve_backup=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(backup.is_dir())

        restore = self._restore(backup)
        self.assertEqual(restore.returncode, 0, restore.stderr)
        self.assertFalse(backup.exists())
        for name in MANAGED_FILES:
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
        for name in MANAGED_FILES:
            self.assertEqual(
                (self.objects / "ssrvpn" / "downloads" / name).read_bytes(),
                self.old[name],
            )
        self.assertEqual(
            (self.objects / "ssrvpn" / "latest.json").read_bytes(),
            self.old["latest.json"],
        )
        self.assertEqual(list(self.root.glob("ssrvpn-oss-backup.*")), [])

    def test_checksum_publish_failure_restores_the_complete_previous_channel(
        self,
    ) -> None:
        backup = self.root / "transaction-backup-checksum-publish-failure"
        before = self._snapshot_public_channel()

        result = self._run(
            fail_on="SSRVPN.dmg.sha256",
            backup=backup,
            preserve_backup=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(backup.is_dir())
        self.assertEqual(self._snapshot_public_channel(), before)
        self._assert_published_pairs_consistent()
        self.assertEqual(self._recovery_scratch_files(backup), [])

    def test_backup_read_failure_never_mutates_the_public_channel(self) -> None:
        result = self._run(backup_fail_on="SSRVPN.dmg")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot authoritatively back up", result.stderr)
        for name in MANAGED_FILES:
            self.assertEqual(
                (self.objects / "ssrvpn" / "downloads" / name).read_bytes(),
                self.old[name],
            )
        self.assertEqual(
            (self.objects / "ssrvpn" / "latest.json").read_bytes(),
            self.old["latest.json"],
        )
        self.assertEqual(list(self.root.glob("ssrvpn-oss-backup.*")), [])

    def test_public_404_cannot_override_authoritative_backup_failure(self) -> None:
        result = self._run(
            backup_fail_on="SSRVPN.zip",
            public_missing_on="SSRVPN.zip",
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cannot authoritatively back up", result.stderr)
        for name in MANAGED_FILES:
            self.assertEqual(
                (self.objects / "ssrvpn" / "downloads" / name).read_bytes(),
                self.old[name],
            )
        self.assertEqual(
            (self.objects / "ssrvpn" / "latest.json").read_bytes(),
            self.old["latest.json"],
        )

    def test_restore_failure_is_reported_instead_of_silently_succeeding(self) -> None:
        result = self._run(
            fail_on="SSRVPN.dmg",
            restore_fail_on="SSRVPN.apk",
        )
        self.assertEqual(result.returncode, 86)
        self.assertIn("recovery is incomplete", result.stderr)
        self._assert_published_pairs_consistent()
        self.assertEqual(
            (self.objects / "ssrvpn" / "latest.json").read_bytes(),
            self.old["latest.json"],
        )

    def test_explicit_restore_keeps_pairs_consistent_and_latest_new_on_any_pair_failure(
        self,
    ) -> None:
        for failed_name in PUBLISHED_FILES:
            with self.subTest(failed_name=failed_name):
                self.old = self._write_channel(self.objects / "ssrvpn", b"old")
                backup = self.root / f"transaction-backup-{failed_name}"
                result = self._run(
                    backup=backup,
                    preserve_backup=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

                restore = self._restore(
                    backup,
                    restore_fail_on=failed_name,
                )

                self.assertEqual(restore.returncode, 86, restore.stderr)
                self._assert_published_pairs_consistent()
                self.assertEqual(
                    (self.objects / "ssrvpn" / "latest.json").read_bytes(),
                    self.manifest.read_bytes(),
                )

    def test_explicit_restore_failure_rolls_back_the_complete_current_channel(
        self,
    ) -> None:
        backup = self.root / "transaction-backup-global-restore-rollback"
        result = self._run(backup=backup, preserve_backup=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        before = self._snapshot_public_channel()

        restore = self._restore(
            backup,
            restore_fail_on="SSRVPN.dmg.sha256",
        )

        self.assertEqual(restore.returncode, 86, restore.stderr)
        self.assertTrue(backup.is_dir())
        self.assertEqual(self._snapshot_public_channel(), before)
        self._assert_published_pairs_consistent()
        self.assertEqual(self._recovery_scratch_files(backup), [])

    def test_restore_rolls_back_pair_when_checksum_write_lands_but_readback_fails(
        self,
    ) -> None:
        backup = self.root / "transaction-backup-write-read-race"
        result = self._run(backup=backup, preserve_backup=True)
        self.assertEqual(result.returncode, 0, result.stderr)

        restore = self._restore(
            backup,
            write_then_verify_fail_on="SSRVPN.apk.sha256",
        )

        self.assertEqual(restore.returncode, 86, restore.stderr)
        self.assertTrue(backup.is_dir())
        self._assert_published_pairs_consistent()
        for name in ("SSRVPN.apk", "SSRVPN.apk.sha256"):
            self.assertEqual(
                (self.objects / "ssrvpn" / "downloads" / name).read_bytes(),
                (self.source / name).read_bytes(),
            )
        self.assertEqual(
            (self.objects / "ssrvpn" / "latest.json").read_bytes(),
            self.manifest.read_bytes(),
        )

    def test_restore_reports_when_the_current_pair_cannot_be_reinstated(
        self,
    ) -> None:
        backup = self.root / "transaction-backup-pair-rollback-failure"
        result = self._run(backup=backup, preserve_backup=True)
        self.assertEqual(result.returncode, 0, result.stderr)

        restore = self._restore(
            backup,
            write_then_verify_fail_on="SSRVPN.apk.sha256",
            fail_current_pair_rollback=True,
        )

        self.assertEqual(restore.returncode, 86, restore.stderr)
        self.assertTrue(backup.is_dir())
        self.assertIn("channel safety rollback failed", restore.stderr)
        self.assertEqual(
            (self.objects / "ssrvpn" / "latest.json").read_bytes(),
            self.manifest.read_bytes(),
        )

    def test_restore_rolls_back_to_an_absent_current_pair_on_target_failure(
        self,
    ) -> None:
        backup = self.root / "transaction-backup-absent-current-pair"
        result = self._run(backup=backup, preserve_backup=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        downloads = self.objects / "ssrvpn" / "downloads"
        for name in ("SSRVPN.apk", "SSRVPN.apk.sha256"):
            (downloads / name).unlink()

        restore = self._restore(
            backup,
            restore_fail_on="SSRVPN.apk.sha256",
        )

        self.assertEqual(restore.returncode, 86, restore.stderr)
        self.assertTrue(backup.is_dir())
        for name in ("SSRVPN.apk", "SSRVPN.apk.sha256"):
            self.assertFalse((downloads / name).exists())
        self.assertEqual(
            (self.objects / "ssrvpn" / "latest.json").read_bytes(),
            self.manifest.read_bytes(),
        )

    def test_backup_uses_authoritative_oss_bytes_instead_of_stale_public_reads(
        self,
    ) -> None:
        stale_objects = self.root / "stale-objects"
        self._write_channel(stale_objects / "ssrvpn", b"stale")
        backup = self.root / "authoritative-backup"

        result = self._run(
            backup=backup,
            preserve_backup=True,
            stale_backup_root=stale_objects,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        for name in MANAGED_FILES:
            self.assertEqual((backup / name).read_bytes(), self.old[name])
        self.assertEqual(
            (backup / "latest.json").read_bytes(),
            self.old["latest.json"],
        )

    def test_public_verification_requests_bypass_caches(self) -> None:
        result = self._run(require_no_cache=True)

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_incoherent_authoritative_backup_fails_before_any_mutation(self) -> None:
        channel = self.objects / "ssrvpn"
        (channel / "downloads" / "SSRVPN.apk.sha256").write_text(
            "0" * 64 + "  SSRVPN.apk\n",
            encoding="utf-8",
        )
        before = {
            name: (channel / "downloads" / name).read_bytes()
            for name in MANAGED_FILES
        }
        before["latest.json"] = (channel / "latest.json").read_bytes()

        result = self._run()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("backup pair", result.stderr)
        for name in MANAGED_FILES:
            self.assertEqual(
                (channel / "downloads" / name).read_bytes(),
                before[name],
            )
        self.assertEqual(
            (channel / "latest.json").read_bytes(),
            before["latest.json"],
        )

    def _run(
        self,
        fail_on: str = "",
        restore_fail_on: str = "",
        backup_fail_on: str = "",
        backup: Optional[Path] = None,
        preserve_backup: bool = False,
        deny_retired_delete: bool = False,
        stale_backup_root: Optional[Path] = None,
        require_no_cache: bool = False,
        public_missing_on: str = "",
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
                "FAKE_DENY_RETIRED_DELETE": "1" if deny_retired_delete else "0",
                "FAKE_STALE_BACKUP_ROOT": str(stale_backup_root or ""),
                "FAKE_REQUIRE_NO_CACHE": "1" if require_no_cache else "0",
                "FAKE_PUBLIC_MISSING_ON": public_missing_on,
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

    def _restore(
        self,
        backup: Path,
        restore_fail_on: str = "",
        write_then_verify_fail_on: str = "",
        fail_current_pair_rollback: bool = False,
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
                "FAKE_NEW_SOURCE": str(self.source),
                "FAKE_RESTORE_FAIL_ON": restore_fail_on,
                "FAKE_RESTORE_WRITE_THEN_READ_FAIL_ON": (
                    write_then_verify_fail_on
                ),
                "FAKE_FAIL_CURRENT_PAIR_ROLLBACK": (
                    "1" if fail_current_pair_rollback else "0"
                ),
            }
        )
        return subprocess.run(
            ["bash", str(SCRIPT), "--restore", str(backup)],
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )

    def _assert_published_pairs_consistent(self) -> None:
        downloads = self.objects / "ssrvpn" / "downloads"
        for name in ("SSRVPN.apk", "SSRVPN.dmg", "SSRVPN_Setup.exe"):
            payload = (downloads / name).read_bytes()
            checksum = (downloads / f"{name}.sha256").read_text(
                encoding="utf-8"
            )
            self.assertIn(hashlib.sha256(payload).hexdigest(), checksum.split())

    def _snapshot_public_channel(self) -> dict[str, Optional[bytes]]:
        channel = self.objects / "ssrvpn"
        snapshot: dict[str, Optional[bytes]] = {}
        for name in MANAGED_FILES:
            path = channel / "downloads" / name
            snapshot[name] = path.read_bytes() if path.is_file() else None
        latest = channel / "latest.json"
        snapshot["latest.json"] = latest.read_bytes() if latest.is_file() else None
        return snapshot

    def _recovery_scratch_files(self, backup: Path) -> list[str]:
        return sorted(
            entry.name
            for entry in backup.iterdir()
            if entry.name.startswith(("restore-", "match-"))
            or entry.name.endswith(".current")
        )

    def _write_channel(self, root: Path, prefix: bytes) -> dict[str, bytes]:
        downloads = root / "downloads" if root != self.source else root
        downloads.mkdir(parents=True, exist_ok=True)
        values: dict[str, bytes] = {}
        binaries = ["SSRVPN.apk", "SSRVPN.dmg", "SSRVPN_Setup.exe"]
        if root != self.source:
            binaries.append("SSRVPN.zip")
        for name in binaries:
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
                state = root / '.fake-state'
                state.mkdir(exist_ok=True)
                def object_path(value):
                    return root / value.split('/', 3)[3]
                if command == 'cp':
                    source, destination = sys.argv[2], sys.argv[3]
                    if source.startswith('oss://'):
                        if os.environ.get('FAKE_BACKUP_FAIL_ON') == pathlib.Path(source).name:
                            raise SystemExit(13)
                        remote = object_path(source)
                        if not remote.is_file():
                            raise SystemExit(12)
                        remaining = state / ('read-fail-' + remote.name)
                        if remaining.is_file():
                            count = int(remaining.read_text())
                            if count > 0:
                                count -= 1
                                if count:
                                    remaining.write_text(str(count))
                                else:
                                    remaining.unlink()
                                raise SystemExit(13)
                        target = pathlib.Path(destination)
                        target.parent.mkdir(parents=True, exist_ok=True)
                        shutil.copyfile(remote, target)
                        raise SystemExit(0)
                    if (os.environ.get('FAKE_FAIL_ON') == pathlib.Path(destination).name
                            and source.startswith(os.environ.get('FAKE_NEW_SOURCE', '') + os.sep)):
                        raise SystemExit(9)
                    if (os.environ.get('FAKE_RESTORE_FAIL_ON') == pathlib.Path(destination).name
                            and destination.startswith('oss://')
                            and not source.startswith(os.environ.get('FAKE_NEW_SOURCE', '') + os.sep)):
                        raise SystemExit(10)
                    if (os.environ.get('FAKE_FAIL_CURRENT_PAIR_ROLLBACK') == '1'
                            and ('.restore-current-' in source
                                 or 'current-pair-' in source)):
                        raise SystemExit(14)
                    target = object_path(destination)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, target)
                    fail_after_write = os.environ.get(
                        'FAKE_RESTORE_WRITE_THEN_READ_FAIL_ON')
                    triggered = state / ('read-fail-triggered-' + target.name)
                    if fail_after_write == target.name and not triggered.exists():
                        triggered.touch()
                        (state / ('read-fail-' + target.name)).write_text('3')
                elif command == 'stat':
                    if not object_path(sys.argv[2]).is_file():
                        print('ServerError: code: NoSuchKey', file=sys.stderr)
                        raise SystemExit(12)
                elif command == 'rm':
                    if (os.environ.get('FAKE_DENY_RETIRED_DELETE') == '1'
                            and pathlib.Path(sys.argv[2]).name in {
                                'SSRVPN.zip', 'SSRVPN.zip.sha256'}):
                        raise SystemExit(11)
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
                import os, pathlib, shutil, sys, urllib.parse
                root = pathlib.Path(os.environ['FAKE_OSS_ROOT'])
                args = sys.argv[1:]
                destination = pathlib.Path(args[args.index('-o') + 1])
                url = next(value for value in reversed(args) if value.startswith('https://'))
                parsed = urllib.parse.urlsplit(url)
                if os.environ.get('FAKE_REQUIRE_NO_CACHE') == '1':
                    headers = [
                        args[index + 1]
                        for index, value in enumerate(args[:-1])
                        if value == '-H'
                    ]
                    if ('Cache-Control: no-cache' not in headers
                            or 'Pragma: no-cache' not in headers
                            or not parsed.query):
                        print('500', end='')
                        raise SystemExit(0)
                object_root = root
                stale_root = os.environ.get('FAKE_STALE_BACKUP_ROOT', '')
                if (stale_root and destination.name in {
                        'SSRVPN.apk', 'SSRVPN.apk.sha256',
                        'SSRVPN.dmg', 'SSRVPN.dmg.sha256',
                        'SSRVPN_Setup.exe', 'SSRVPN_Setup.exe.sha256',
                        'SSRVPN.zip', 'SSRVPN.zip.sha256', 'latest.json'}):
                    object_root = pathlib.Path(stale_root)
                path = object_root / parsed.path.lstrip('/')
                if os.environ.get('FAKE_PUBLIC_MISSING_ON') == path.name:
                    print('404', end='')
                    raise SystemExit(0)
                backup_failure = os.environ.get('FAKE_BACKUP_FAIL_ON')
                if backup_failure and destination.name in {
                        backup_failure, f'public-{backup_failure}'}:
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
