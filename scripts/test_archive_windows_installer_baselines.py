import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest import mock

from scripts import archive_windows_installer_baselines as archive


class ArchiveBaselineTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.data = b"verified historical installer bytes"
        self.source = {
            "tag": "v5.0.18",
            "url": archive.ARCHIVE_BASE + "/v5.0.18/SSRVPN_Setup.exe",
            "originalUrl": archive.GITHUB_BASE + "/v5.0.18/SSRVPN_Setup.exe",
            "sha256": hashlib.sha256(self.data).hexdigest(),
        }

    def downloader(self, responses):
        values = iter(responses)

        def download(_url, path):
            data = next(values)
            if data is None:
                return False
            path.write_bytes(data)
            return True
        return download

    def exercise(self, responses):
        return mock.patch.object(archive, "fetch", side_effect=self.downloader(responses))

    def test_matching_archive_is_read_only(self):
        with self.exercise([self.data]), mock.patch.object(archive.subprocess, "run") as run:
            result = archive.archive_one(self.source, self.root, True)
        self.assertEqual(result["action"], "verified-existing")
        run.assert_not_called()

    def test_corrupt_existing_archive_is_never_replaced(self):
        with self.exercise([b"different"]), mock.patch.object(archive.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                archive.archive_one(self.source, self.root, True)
        run.assert_not_called()

    def test_missing_archive_requires_upload_and_verified_original(self):
        with self.exercise([None]), mock.patch.object(archive.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "Missing archive"):
                archive.archive_one(self.source, self.root, False)
        run.assert_not_called()
        with self.exercise([None, b"untrusted"]), mock.patch.object(archive.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                archive.archive_one(self.source, self.root, True)
        run.assert_not_called()

    def test_missing_archive_is_uploaded_without_overwrite_and_read_back(self):
        with self.exercise([None, self.data, self.data]), mock.patch.object(archive.subprocess, "run") as run:
            result = archive.archive_one(self.source, self.root, True)
        self.assertEqual(result["action"], "archived-and-verified")
        self.assertEqual(result["bytes"], len(self.data))
        run.assert_called_once_with([
            "ossutil", "cp", str(self.root / "original.exe"),
            archive.OBJECT_BASE + "/v5.0.18/SSRVPN_Setup.exe", "--ignore-existing",
        ], check=True)

    def test_racing_different_object_fails_readback(self):
        with self.exercise([None, self.data, b"concurrent-different-object"]), mock.patch.object(archive.subprocess, "run"):
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                archive.archive_one(self.source, self.root, True)

    def test_upload_cannot_run_on_a_workstation_or_pr(self):
        for environment in ({}, {"GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": "Elegying/SSRVPN", "GITHUB_REF": "refs/pull/1/merge"}):
            with self.subTest(environment=environment), mock.patch.dict(archive.os.environ, environment, clear=True):
                with self.assertRaisesRegex(RuntimeError, "main maintenance job"):
                    archive.require_upload_environment()

    def test_source_destinations_are_validated(self):
        sources = archive.load_sources()
        self.assertEqual(len(sources), 16)
        invalid = [dict(sources[0], url="https://example.invalid/replacement.exe")]
        with mock.patch.object(archive.json, "loads", return_value=invalid):
            with self.assertRaisesRegex(ValueError, "archive destination"):
                archive.load_sources()


if __name__ == "__main__":
    unittest.main()
