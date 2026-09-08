import copy
from datetime import datetime, timezone
import hashlib
import importlib.util
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("core_reuse", ROOT / "scripts/reuse-ci-core-assets.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
REPO = "Elegying/SSRVPN"
SHA = "a" * 40
NOW = datetime(2026, 9, 8, 12, tzinfo=timezone.utc)


class ReuseCiCoreAssetsTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.archive = self.root / "cores.zip"
        self.payloads = {name: name.encode() for name in MODULE.ASSETS}
        for name, (record, field) in MODULE.ASSETS.items():
            if "geoip" in name:
                self.payloads[name] = b"geoip"
            destination = self.root / record
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(f"{field}: {hashlib.sha256(self.payloads[name]).hexdigest()}\n")
        self.run = {
            "id": 777, "workflow_id": 321, "head_branch": "main", "head_sha": SHA,
            "path": ".github/workflows/ci.yml@refs/heads/main", "event": "push",
            "status": "completed", "conclusion": "success",
            "html_url": f"https://github.com/{REPO}/actions/runs/777",
            "created_at": "2026-09-08T11:00:00Z",
            "repository": {"id": 10, "full_name": REPO},
            "head_repository": {"id": 10, "full_name": REPO},
        }
        self.jobs = [{
            "run_id": 777, "head_sha": SHA, "name": name, "id": index,
            "status": "completed", "conclusion": "skipped" if name == "Dependency review" else "success",
        } for index, name in enumerate(MODULE.CI.load_required_names(
            ROOT / ".github/main-branch-protection.json"), start=1)]
        self.artifact = {
            "id": 888, "name": "core-assets", "size_in_bytes": 5000,
            "url": f"https://api.github.com/repos/{REPO}/actions/artifacts/888",
            "archive_download_url": f"https://api.github.com/repos/{REPO}/actions/artifacts/888/zip",
            "expired": False, "expires_at": "2026-09-09T12:00:00Z",
            "workflow_run": {"id": 777, "head_sha": SHA, "head_branch": "main",
                             "repository_id": 10, "head_repository_id": 10},
        }
        self.write_archive(self.payloads)

    def write_archive(self, payloads):
        with zipfile.ZipFile(self.archive, "w") as archive:
            for name, data in payloads.items():
                archive.writestr(name, data)
        self.artifact["digest"] = "sha256:" + MODULE.file_digest(self.archive)
        self.artifact["size_in_bytes"] = self.archive.stat().st_size

    def api(self, endpoint):
        if endpoint.endswith("/runs/777"):
            return copy.deepcopy(self.run)
        if endpoint.endswith("/artifacts/888"):
            return copy.deepcopy(self.artifact)
        raise AssertionError(endpoint)

    def pages(self, endpoint, _collection, _fields):
        if endpoint.endswith("/jobs"):
            return self.jobs
        if endpoint.endswith("/artifacts"):
            return self.artifacts
        if endpoint.endswith("/runs"):
            return self.runs
        raise AssertionError(endpoint)

    def restore(self, *, run_id=777):
        self.artifacts = getattr(self, "artifacts", [self.artifact])
        self.runs = getattr(self, "runs", [self.run])
        with patch.object(MODULE.CI, "canonical_workflow_id", return_value=321), \
                patch.object(MODULE.CI, "gh_api_json", side_effect=self.api), \
                patch.object(MODULE.CI, "paginated_items", side_effect=self.pages), \
                patch.object(MODULE, "download_archive", side_effect=lambda repo, artifact, target:
                             shutil.copyfile(self.archive, target)):
            return MODULE.restore(REPO, SHA, run_id, now=NOW, root=self.root)

    def test_exact_successful_main_installs_all_pinned_assets(self):
        self.assertTrue(self.restore(run_id=None))
        for name, data in self.payloads.items():
            self.assertEqual((self.root / name).read_bytes(), data)

    def test_absent_or_expired_assets_allow_rebuild(self):
        self.artifacts = []
        self.assertFalse(self.restore())
        self.artifacts = [self.artifact]
        self.artifact["expired"] = True
        self.assertFalse(self.restore())
        self.artifact["expired"] = False
        self.artifact["expires_at"] = "2026-09-08T11:00:00Z"
        self.assertFalse(self.restore())

    def test_absent_or_old_successful_run_allows_rebuild(self):
        self.runs = []
        self.assertFalse(self.restore(run_id=None))
        self.run["created_at"] = "2026-09-07T10:59:59Z"
        self.assertFalse(self.restore())

    def test_wrong_run_identity_and_conclusion_fail_closed(self):
        changes = (
            ("id", 999), ("workflow_id", 999), ("head_sha", "b" * 40),
            ("head_branch", "other"), ("path", ".github/workflows/other.yml"),
            ("event", "pull_request"), ("conclusion", "failure"),
            ("status", "in_progress"), ("repository", {"id": 10, "full_name": "other/repo"}),
            ("head_repository", {"id": 20, "full_name": "other/repo"}),
            ("created_at", "2026-09-09T12:00:00Z"),
        )
        baseline = copy.deepcopy(self.run)
        for field, value in changes:
            with self.subTest(field=field):
                self.run = {**baseline, field: value}
                with self.assertRaises(MODULE.CI.VerificationError):
                    self.restore()

    def test_missing_duplicate_failed_or_wrong_sha_jobs_fail_closed(self):
        baseline = copy.deepcopy(self.jobs)
        variants = (baseline[:-1], baseline + [baseline[-1]],
                    [{**job, "conclusion": "skipped"} if job["name"] == "macOS" else job for job in baseline],
                    [{**job, "head_sha": "b" * 40} for job in baseline])
        for jobs in variants:
            with self.subTest(jobs=jobs):
                self.jobs = jobs
                with self.assertRaises(MODULE.CI.VerificationError):
                    self.restore()

    def test_wrong_artifact_identity_metadata_or_duplicates_fail_closed(self):
        baseline = copy.deepcopy(self.artifact)
        changes = (
            ("workflow_run", {**baseline["workflow_run"], "id": 999}),
            ("workflow_run", {**baseline["workflow_run"], "head_repository_id": 20}),
            ("workflow_run", {**baseline["workflow_run"], "head_sha": "b" * 40}),
            ("archive_download_url", "https://example.org/cores.zip"),
            ("digest", None), ("expired", "false"), ("size_in_bytes", MODULE.MAX_BYTES + 1),
        )
        for field, value in changes:
            with self.subTest(field=field):
                self.artifact = {**baseline, field: value}
                self.artifacts = [self.artifact]
                with self.assertRaises(MODULE.CI.VerificationError):
                    self.restore()
        self.artifact = baseline
        self.artifacts = [baseline, baseline]
        with self.assertRaises(MODULE.CI.VerificationError):
            self.restore()

    def test_artifact_identity_change_between_reads_fails_closed(self):
        self.artifacts = [copy.deepcopy(self.artifact)]
        self.artifact["digest"] = "sha256:" + "b" * 64
        for expired in (False, True):
            self.artifact["expired"] = expired
            with self.subTest(expired=expired):
                with self.assertRaisesRegex(MODULE.CI.VerificationError, "identity changed"):
                    self.restore()

    def test_network_error_does_not_allow_rebuild(self):
        with patch.object(MODULE.CI, "canonical_workflow_id", side_effect=MODULE.CI.VerificationError("API error")):
            with self.assertRaises(MODULE.CI.VerificationError):
                MODULE.restore(REPO, SHA, now=NOW)

    def test_ci_rerun_during_download_blocks_installation(self):
        with patch.object(MODULE, "trusted_run", side_effect=[
            self.run, MODULE.CI.VerificationError("CI restarted"),
        ]):
            with self.assertRaisesRegex(MODULE.CI.VerificationError, "restarted"):
                self.restore()
        self.assertTrue(all(not (self.root / name).exists() for name in self.payloads))

    def test_archive_and_each_asset_digest_are_checked_before_install(self):
        self.artifact["size_in_bytes"] += 1
        with self.assertRaisesRegex(MODULE.CI.VerificationError, "archive size"):
            self.restore()
        self.artifact["size_in_bytes"] -= 1
        self.artifact["digest"] = "sha256:" + "b" * 64
        with self.assertRaisesRegex(MODULE.CI.VerificationError, "archive SHA"):
            self.restore()
        first = next(iter(self.payloads))
        self.write_archive({**self.payloads, first: b"modified"})
        with self.assertRaisesRegex(MODULE.CI.VerificationError, "pinned core SHA"):
            self.restore()
        for name in self.payloads:
            self.assertFalse((self.root / name).exists())

    def test_zip_path_traversal_extra_missing_duplicate_and_symlink_rejected(self):
        for name in ("../escaped", "/tmp/escaped", "unexpected"):
            with self.subTest(name=name):
                self.write_archive({**self.payloads, name: b"x"})
                with self.assertRaisesRegex(MODULE.CI.VerificationError, "file set"):
                    self.restore()
        self.write_archive(dict(list(self.payloads.items())[1:]))
        with self.assertRaisesRegex(MODULE.CI.VerificationError, "file set"):
            self.restore()
        self.write_archive(self.payloads)
        with zipfile.ZipFile(self.archive, "a") as archive:
            archive.writestr(next(iter(self.payloads)), b"duplicate")
        self.artifact["digest"] = "sha256:" + MODULE.file_digest(self.archive)
        self.artifact["size_in_bytes"] = self.archive.stat().st_size
        with self.assertRaisesRegex(MODULE.CI.VerificationError, "file set"):
            self.restore()
        with zipfile.ZipFile(self.archive, "w") as archive:
            for name, data in self.payloads.items():
                entry = zipfile.ZipInfo(name)
                entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(entry, data)
        self.artifact["digest"] = "sha256:" + MODULE.file_digest(self.archive)
        self.artifact["size_in_bytes"] = self.archive.stat().st_size
        with self.assertRaisesRegex(MODULE.CI.VerificationError, "non-regular"):
            self.restore()

    def test_rebuild_wrapper_only_accepts_unavailable_exit_code(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copyfile(ROOT / "scripts/prepare-release-core-assets.sh", scripts / "prepare-release-core-assets.sh")
        for script in ("bootstrap-core-assets.sh", "verify-core-assets.sh"):
            (scripts / script).write_text(f'echo "{script}" >> "$CALL_LOG"\n')
        binaries = self.root / "bin"
        binaries.mkdir()
        for name, source in {"git": f"echo {SHA}", "python3": 'exit "$FAKE_STATUS"'}.items():
            path = binaries / name
            path.write_text("#!/bin/sh\n" + source + "\n")
            path.chmod(0o755)
        for status in (0, 3, 2, 4):
            with self.subTest(status=status):
                log = self.root / f"calls-{status}"
                result = subprocess.run(["bash", str(scripts / "prepare-release-core-assets.sh"), "777"],
                                        cwd=self.root, capture_output=True, text=True,
                                        env={**os.environ, "PATH": f"{binaries}:{os.environ['PATH']}",
                                             "GITHUB_REPOSITORY": REPO, "FAKE_STATUS": str(status), "CALL_LOG": str(log)})
                calls = log.read_text() if log.exists() else ""
                self.assertEqual(result.returncode, 0 if status in (0, 3) else status)
                self.assertEqual("bootstrap-core-assets.sh" in calls, status == 3)
                self.assertEqual("verify-core-assets.sh" in calls, status in (0, 3))


if __name__ == "__main__":
    unittest.main()
