import hashlib
import io
from pathlib import Path
import tempfile
import unittest
import zipfile
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

    def test_explicit_tag_selects_only_the_exact_baseline(self):
        self.assertEqual(archive.load_sources("v5.0.19"), [archive.V5019])
        self.assertEqual(len(archive.load_sources()), 16)
        self.assertEqual(archive.load_sources("v5.0.18")[0]["tag"], "v5.0.18")
        for tag in ("v5.0.99", "../v5.0.19", "v5.0.19; echo unsafe"):
            with self.subTest(tag=tag), self.assertRaisesRegex(ValueError, "Unknown"):
                archive.load_sources(tag)

    def test_v5019_pin_matches_the_unchanged_installer_regression(self):
        regression = (archive.ROOT / "scripts/test_windows_installer_ownership_package.ps1").read_text()
        self.assertIn(archive.V5019["sha256"], regression)
        self.assertIn(archive.V5019["url"], regression)
        self.assertEqual(archive.V5019_ARTIFACT["artifactId"], 10810332465)
        self.assertEqual(archive.V5019_ARTIFACT["runId"], 36004003483)

    def test_missing_v5019_recovers_original_artifact_before_upload(self):
        source = dict(archive.V5019, sha256=hashlib.sha256(self.data).hexdigest())
        def recover(path):
            path.write_bytes(self.data)
        with mock.patch.object(archive, "V5019", source), self.exercise([None, None, self.data]), \
                mock.patch.object(archive, "recover_v5019_artifact", side_effect=recover) as recovery, \
                mock.patch.object(archive.subprocess, "run") as run:
            result = archive.archive_one(source, self.root, True)
        recovery.assert_called_once_with(self.root / "original.exe")
        self.assertEqual(result["action"], "archived-and-verified")
        self.assertEqual(run.call_args.args[0][-1], "--ignore-existing")
        self.assertIn("/v5.0.19/SSRVPN_Setup.exe", run.call_args.args[0][-2])

    def test_existing_v5019_does_not_need_original_artifact(self):
        with self.exercise([b"wrong"]), mock.patch.object(archive, "recover_v5019_artifact") as recovery, \
                mock.patch.object(archive.subprocess, "run") as run:
            with self.assertRaisesRegex(ValueError, "SHA-256 mismatch"):
                archive.archive_one(archive.V5019, self.root, True)
        recovery.assert_not_called()
        run.assert_not_called()

    def test_unavailable_recovery_stops_before_upload(self):
        with self.exercise([None, None]), \
                mock.patch.object(archive, "recover_v5019_artifact", side_effect=RuntimeError("expired")), \
                mock.patch.object(archive.subprocess, "run") as run:
            with self.assertRaisesRegex(RuntimeError, "expired"):
                archive.archive_one(archive.V5019, self.root, True)
        run.assert_not_called()

    def artifact(self, name="SSRVPN_Setup.exe", data=None):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as output:
            output.writestr(name, self.data if data is None else data)
        return buffer.getvalue()

    def recover_artifact(self, data, **overrides):
        metadata = dict(archive.V5019_ARTIFACT, bytes=len(data),
                        sha256=hashlib.sha256(data).hexdigest(), installerBytes=len(self.data))
        metadata.update(overrides)
        def download(command, **kwargs):
            self.assertEqual(command, ["gh", "api", "repos/Elegying/SSRVPN/actions/artifacts/10810332465/zip"])
            self.assertEqual(kwargs["timeout"], 180)
            self.assertTrue(kwargs["check"])
            kwargs["stdout"].write(data)
        with mock.patch.object(archive, "V5019_ARTIFACT", metadata), \
                mock.patch.dict(archive.V5019, sha256=hashlib.sha256(self.data).hexdigest()), \
                mock.patch.object(archive.subprocess, "run", side_effect=download):
            target = self.root / "installer.exe"
            archive.recover_v5019_artifact(target)
        return target.read_bytes()

    def test_original_artifact_is_verified_and_only_known_member_read(self):
        self.assertEqual(self.recover_artifact(self.artifact()), self.data)

    def test_artifact_size_and_hash_are_fail_closed(self):
        for overrides in ({"bytes": 1}, {"sha256": "0" * 64}, {"installerBytes": 1}):
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                self.recover_artifact(self.artifact(), **overrides)

    def test_unknown_archive_paths_and_installer_bytes_are_rejected(self):
        for data in (self.artifact("../SSRVPN_Setup.exe"), self.artifact(data=b"x" * len(self.data))):
            with self.subTest(data=data), self.assertRaises(ValueError):
                self.recover_artifact(data)

    def test_recovery_workflow_keeps_main_only_dispatch_and_quoted_tag(self):
        workflow = (archive.ROOT / ".github/workflows/maintenance.yml").read_text()
        job = workflow.split("  windows-installer-archive:\n", 1)[1].split("  windows-public-installer:\n", 1)[0]
        self.assertIn("github.event_name == 'workflow_dispatch'", job)
        self.assertIn("github.ref == 'refs/heads/main'", job)
        self.assertIn("      actions: read\n", job)
        self.assertIn("          BASELINE_TAG: ${{ inputs.tag }}", job)
        self.assertIn('--tag "$BASELINE_TAG"', job)
        self.assertNotIn("--force", job)


if __name__ == "__main__":
    unittest.main()
