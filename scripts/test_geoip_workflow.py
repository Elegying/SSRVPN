import importlib.util
import gzip
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from pathlib import Path
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "sync_geoip_metadb",
    ROOT / "scripts/sync-geoip-metadb.py",
)
assert SPEC is not None and SPEC.loader is not None
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _stable_gzip(data: bytes) -> bytes:
    compressed = gzip.compress(data, compresslevel=9, mtime=0)
    return compressed[:9] + b"\xff" + compressed[10:]


def _write_source_record(path: Path, *, raw: bytes, gzipped: bytes) -> str:
    gzip_hash = _sha256(gzipped)
    mirror_name = f"geoip.metadb-{gzip_hash}.gz"
    mirror_url = (
        "https://github.com/Elegying/SSRVPN/releases/download/"
        f"core-assets-v1/{mirror_name}"
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join(
            [
                "Repo: MetaCubeX/meta-rules-dat",
                "Release ID: stale-release",
                "Release tag: latest",
                "Release name: stale upstream pin",
                "Asset ID: stale-asset",
                (
                    "Asset URL: https://api.github.com/repos/MetaCubeX/"
                    "meta-rules-dat/releases/assets/404"
                ),
                f"Upstream SHA256: {_sha256(raw)}",
                f"Bundled gzip SHA256: {gzip_hash}",
                "Mirror repo: Elegying/SSRVPN",
                "Mirror release tag: core-assets-v1",
                f"Mirror asset name: {mirror_name}",
                f"Mirror URL: {mirror_url}",
                "",
            ]
        ),
        encoding="utf-8",
    )
    return mirror_url


def _write_bootstrap_fixture(root: Path, *, raw: bytes, gzipped: bytes) -> str:
    scripts = root / "scripts"
    scripts.mkdir(parents=True)
    bootstrap = scripts / "bootstrap-core-assets.sh"
    shutil.copy2(ROOT / "scripts/bootstrap-core-assets.sh", bootstrap)
    bootstrap.chmod(0o755)
    verify = scripts / "verify-core-assets.sh"
    verify.write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")
    verify.chmod(0o755)

    android = b"android-core"
    android_asset = (
        root
        / "SSRVPN_Android/android/app/src/main/jniLibs/arm64-v8a/libgojni.so"
    )
    android_asset.parent.mkdir(parents=True)
    android_asset.write_bytes(android)
    android_source = root / "SSRVPN_Android/assets/libgojni-source.txt"
    android_source.parent.mkdir(parents=True)
    android_source.write_text(
        "\n".join(
            [
                "Container URL: https://github.com/example/android.apk",
                f"Container SHA256: {_sha256(b'unused-container')}",
                "Library member: lib/arm64-v8a/libgojni.so",
                f"Library SHA256: {_sha256(android)}",
                "",
            ]
        ),
        encoding="utf-8",
    )

    macos = b"macos-core"
    macos_asset = root / "SSRVPN_MacOS/assets/AtlasCore.gz"
    macos_asset.parent.mkdir(parents=True)
    macos_asset.write_bytes(macos)
    (root / "SSRVPN_MacOS/assets/AtlasCore-source.txt").write_text(
        "\n".join(
            [
                "Official asset URL: https://github.com/example/macos.gz",
                f"Official asset SHA256: {_sha256(macos)}",
                "",
            ]
        ),
        encoding="utf-8",
    )

    windows = b"windows-core"
    windows_asset = root / "SSRVPN_Windows/assets/mihomo.exe"
    windows_asset.parent.mkdir(parents=True)
    windows_asset.write_bytes(windows)
    (root / "SSRVPN_Windows/assets/mihomo-source.txt").write_text(
        "\n".join(
            [
                "Official asset URL: https://github.com/example/windows.zip",
                f"Official asset SHA256: {_sha256(b'unused-container')}",
                "Executable member: mihomo.exe",
                f"Executable SHA256: {_sha256(windows)}",
                "",
            ]
        ),
        encoding="utf-8",
    )

    return _write_source_record(
        root / "docs/GEOIP_SOURCE.txt",
        raw=raw,
        gzipped=gzipped,
    )


class _FakeResponse(BytesIO):
    headers = {}

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        self.close()


class _DripResponse:
    headers = {}

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return None

    def read1(self, _size):
        return b"x"


class GeoIpWorkflowTest(unittest.TestCase):
    def _load_mirror_module(self):
        path = ROOT / "scripts/ensure-geoip-mirror.py"
        self.assertTrue(path.is_file(), f"missing {path.relative_to(ROOT)}")
        spec = importlib.util.spec_from_file_location("ensure_geoip_mirror", path)
        assert spec is not None and spec.loader is not None
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_github_token_is_only_sent_to_the_api_origin(self) -> None:
        with patch.dict(os.environ, {"GITHUB_TOKEN": "test-token"}):
            api_request = SYNC.request("https://api.github.com/repos/example")
            asset_request = SYNC.request("https://github.com/example/download")

        self.assertEqual(api_request.get_header("Authorization"), "Bearer test-token")
        self.assertIsNone(asset_request.get_header("Authorization"))

    def test_download_rejects_a_response_larger_than_its_limit(self) -> None:
        response = _FakeResponse(b"12345")
        with patch.object(SYNC.urllib.request, "urlopen", return_value=response):
            with self.assertRaisesRegex(SystemExit, "exceeds the 4 byte limit"):
                SYNC.download("https://example.com/asset", max_bytes=4)

    def test_download_has_an_absolute_deadline_for_slow_drips(self) -> None:
        with patch.object(
            SYNC.urllib.request,
            "urlopen",
            return_value=_DripResponse(),
        ), patch.object(SYNC.time, "monotonic", side_effect=[0, 0, 30, 61]):
            with self.assertRaisesRegex(SystemExit, "absolute deadline"):
                SYNC.download("https://example.com/slow", max_bytes=1024)

    def test_authenticated_github_api_downloads_disable_redirects(self) -> None:
        opener = Mock()
        opener.open.return_value = _FakeResponse(b"api response")
        with patch.dict(os.environ, {"GITHUB_TOKEN": "test-token"}), patch.object(
            SYNC.urllib.request,
            "build_opener",
            return_value=opener,
        ) as build_opener, patch.object(
            SYNC.urllib.request,
            "urlopen",
            return_value=_FakeResponse(b"redirected response"),
        ) as urlopen:
            content = SYNC.download(
                "https://api.github.com/repos/MetaCubeX/meta-rules-dat/releases/latest",
                max_bytes=1024,
            )

        self.assertEqual(content, b"api response")
        handler = build_opener.call_args.args[0]
        self.assertIsInstance(handler, SYNC.NoRedirectHandler)
        opener.open.assert_called_once()
        request = opener.open.call_args.args[0]
        self.assertEqual(request.get_header("Authorization"), "Bearer test-token")
        self.assertIsNone(
            handler.redirect_request(
                request,
                None,
                302,
                "Found",
                {},
                "https://attacker.example/asset",
            )
        )
        urlopen.assert_not_called()

    def test_source_record_points_to_content_addressed_ssrvpn_mirror(self) -> None:
        gzip_hash = "b" * 64
        record = SYNC.build_source_record(
            {"id": 1, "tag_name": "latest", "name": "upstream"},
            {"id": 2, "url": "https://api.github.com/upstream/2"},
            "a" * 64,
            gzip_hash,
        )

        mirror_name = f"geoip.metadb-{gzip_hash}.gz"
        self.assertIn("Mirror repo: Elegying/SSRVPN", record)
        self.assertIn("Mirror release tag: core-assets-v1", record)
        self.assertIn(f"Mirror asset name: {mirror_name}", record)
        self.assertIn(
            "Mirror URL: https://github.com/Elegying/SSRVPN/releases/download/"
            f"core-assets-v1/{mirror_name}",
            record,
        )

    def test_clean_bootstrap_ignores_a_deleted_upstream_asset(self) -> None:
        raw = b"verified upstream GeoIP payload"
        gzipped = _stable_gzip(raw)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            mirror_url = _write_bootstrap_fixture(root, raw=raw, gzipped=gzipped)
            mirror_file = root / "mirror.gz"
            mirror_file.write_bytes(gzipped)

            fake_bin = root / "fake-bin"
            fake_bin.mkdir()
            fake_curl = fake_bin / "curl"
            fake_curl.write_text(
                """#!/usr/bin/env bash
set -euo pipefail
args=("$@")
output=""
for ((index = 0; index < ${#args[@]}; index++)); do
  if [ "${args[$index]}" = "--output" ]; then
    output="${args[$((index + 1))]}"
  fi
done
url="${args[$((${#args[@]} - 1))]}"
printf '%s\\n' "$url" >> "$FAKE_CURL_LOG"
if [ "$url" != "$FAKE_MIRROR_URL" ]; then
  echo "simulated deleted upstream asset: $url" >&2
  exit 22
fi
cp "$FAKE_MIRROR_FILE" "$output"
""",
                encoding="utf-8",
            )
            fake_curl.chmod(0o755)
            log = root / "curl.log"
            log.touch()
            env = os.environ.copy()
            env.update(
                {
                    "PATH": f"{fake_bin}:{env['PATH']}",
                    "FAKE_CURL_LOG": str(log),
                    "FAKE_MIRROR_FILE": str(mirror_file),
                    "FAKE_MIRROR_URL": mirror_url,
                }
            )

            result = subprocess.run(
                ["bash", "scripts/bootstrap-core-assets.sh"],
                cwd=root,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )

            self.assertEqual(result.returncode, 0, result.stderr)
            requested_urls = log.read_text(encoding="utf-8").splitlines()
            self.assertEqual(requested_urls, [mirror_url])
            for asset in (
                "SSRVPN_Android/assets/geoip.metadb.gz",
                "SSRVPN_MacOS/assets/geoip.metadb.gz",
                "SSRVPN_Windows/assets/geoip.metadb.gz",
            ):
                self.assertEqual((root / asset).read_bytes(), gzipped)

    def test_mirror_url_guard_is_limited_to_the_support_release(self) -> None:
        mirror = self._load_mirror_module()
        asset_name = f"geoip.metadb-{'a' * 64}.gz"
        expected = (
            "https://github.com/Elegying/SSRVPN/releases/download/"
            f"core-assets-v1/{asset_name}"
        )
        mirror.validate_mirror_url(expected, asset_name)

        for rejected in (
            f"http://github.com/Elegying/SSRVPN/releases/download/core-assets-v1/{asset_name}",
            f"https://github.com/MetaCubeX/meta-rules-dat/releases/download/core-assets-v1/{asset_name}",
            f"https://github.com/Elegying/SSRVPN/releases/download/latest/{asset_name}",
            f"https://github.com/Elegying/SSRVPN/releases/download/core-assets-v1/other.gz",
        ):
            with self.subTest(url=rejected):
                with self.assertRaisesRegex(SystemExit, "approved GeoIP mirror"):
                    mirror.validate_mirror_url(rejected, asset_name)

    def test_mirror_readback_redirects_require_official_https_hosts(self) -> None:
        mirror = self._load_mirror_module()
        for rejected in (
            "http://release-assets.githubusercontent.com/asset",
            "https://example.com/asset",
            "https://raw.githubusercontent.com/Elegying/SSRVPN/main/asset",
        ):
            with self.subTest(url=rejected):
                with self.assertRaisesRegex(
                    SystemExit,
                    "approved GitHub HTTPS download host",
                ):
                    mirror.validate_download_url(rejected)

        original = mirror.urllib.request.Request(
            "https://github.com/Elegying/SSRVPN/releases/download/core-assets-v1/asset",
            headers={"Authorization": "Bearer must-not-follow"},
        )
        handler = mirror.MirrorRedirectHandler()
        redirected = handler.redirect_request(
            original,
            None,
            302,
            "Found",
            {},
            "https://release-assets.githubusercontent.com/github-production-release-asset/asset",
        )
        self.assertIsNotNone(redirected)
        assert redirected is not None
        self.assertIsNone(redirected.get_header("Authorization"))

        for rejected_redirect in (
            "http://release-assets.githubusercontent.com/asset",
            "https://attacker.example/asset",
        ):
            with self.subTest(redirect=rejected_redirect):
                with self.assertRaisesRegex(
                    SystemExit,
                    "approved GitHub HTTPS download host",
                ):
                    handler.redirect_request(
                        original,
                        None,
                        302,
                        "Found",
                        {},
                        rejected_redirect,
                    )

    def test_mirror_download_installs_the_restricted_redirect_handler(self) -> None:
        mirror = self._load_mirror_module()
        opener = Mock()
        opener.open.return_value = _FakeResponse(b"mirror bytes")
        url = (
            "https://github.com/Elegying/SSRVPN/releases/download/"
            "core-assets-v1/asset"
        )
        with patch.object(
            mirror.urllib.request,
            "build_opener",
            return_value=opener,
        ) as build_opener, patch.object(
            mirror.urllib.request,
            "urlopen",
        ) as urlopen:
            content = mirror.download(url, max_bytes=1024)

        self.assertEqual(content, b"mirror bytes")
        handler = build_opener.call_args.args[0]
        self.assertIsInstance(handler, mirror.MirrorRedirectHandler)
        urlopen.assert_not_called()

    def test_mirror_verification_checks_gzip_and_raw_sha256(self) -> None:
        mirror = self._load_mirror_module()
        raw = b"geoip"
        gzipped = _stable_gzip(raw)
        mirror.verify_payload(
            gzipped,
            expected_gzip_hash=_sha256(gzipped),
            expected_raw_hash=_sha256(raw),
        )

        with self.assertRaisesRegex(SystemExit, "gzip SHA256 mismatch"):
            mirror.verify_payload(
                gzipped,
                expected_gzip_hash="0" * 64,
                expected_raw_hash=_sha256(raw),
            )
        with self.assertRaisesRegex(SystemExit, "raw SHA256 mismatch"):
            mirror.verify_payload(
                gzipped,
                expected_gzip_hash=_sha256(gzipped),
                expected_raw_hash="0" * 64,
            )

    def test_mirror_publish_requires_the_named_support_release(self) -> None:
        mirror = self._load_mirror_module()
        raw = b"geoip"
        gzipped = _stable_gzip(raw)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "GEOIP_SOURCE.txt"
            local_asset = root / "geoip.metadb.gz"
            _write_source_record(source, raw=raw, gzipped=gzipped)
            local_asset.write_bytes(gzipped)
            missing = subprocess.CompletedProcess(
                args=["gh", "release", "view"],
                returncode=1,
                stdout="",
                stderr="release not found",
            )

            with patch.object(mirror, "run_gh", return_value=missing):
                with self.assertRaisesRegex(
                    SystemExit,
                    "support release Elegying/SSRVPN@core-assets-v1.*missing",
                ):
                    mirror.ensure_mirror(
                        source_path=source,
                        local_asset=local_asset,
                        upload=True,
                    )

    def test_mirror_support_release_must_be_a_published_prerelease(self) -> None:
        mirror = self._load_mirror_module()
        for metadata in (
            {
                "tagName": "core-assets-v1",
                "isDraft": True,
                "isPrerelease": True,
                "assets": [],
            },
            {
                "tagName": "core-assets-v1",
                "isDraft": False,
                "isPrerelease": False,
                "assets": [],
            },
        ):
            with self.subTest(metadata=metadata):
                response = subprocess.CompletedProcess(
                    args=["gh", "release", "view"],
                    returncode=0,
                    stdout=json.dumps(metadata),
                    stderr="",
                )
                with patch.object(mirror, "run_gh", return_value=response):
                    with self.assertRaisesRegex(
                        SystemExit,
                        "must be a published prerelease",
                    ):
                        mirror.release_asset_names()

    def test_missing_mirror_asset_is_uploaded_without_overwrite_then_read_back(
        self,
    ) -> None:
        mirror = self._load_mirror_module()
        raw = b"geoip"
        gzipped = _stable_gzip(raw)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "GEOIP_SOURCE.txt"
            local_asset = root / "geoip.metadb.gz"
            mirror_url = _write_source_record(source, raw=raw, gzipped=gzipped)
            local_asset.write_bytes(gzipped)
            asset_name = f"geoip.metadb-{_sha256(gzipped)}.gz"
            view = subprocess.CompletedProcess(
                args=["gh", "release", "view"],
                returncode=0,
                stdout=(
                    '{"tagName":"core-assets-v1","isDraft":false,'
                    '"isPrerelease":true,"assets":[]}'
                ),
                stderr="",
            )
            upload = subprocess.CompletedProcess(
                args=["gh", "release", "upload"],
                returncode=0,
                stdout="",
                stderr="",
            )
            present = subprocess.CompletedProcess(
                args=["gh", "release", "view"],
                returncode=0,
                stdout=json.dumps(
                    {
                        "tagName": "core-assets-v1",
                        "isDraft": False,
                        "isPrerelease": True,
                        "assets": [{"name": asset_name}],
                    }
                ),
                stderr="",
            )

            with patch.object(
                mirror,
                "run_gh",
                side_effect=[view, upload, present],
            ) as gh:
                with patch.object(
                    mirror,
                    "download",
                    return_value=gzipped,
                ) as download:
                    mirror.ensure_mirror(
                        source_path=source,
                        local_asset=local_asset,
                        upload=True,
                    )

            upload_command = gh.call_args_list[1].args[0]
            self.assertEqual(gh.call_count, 3)
            self.assertEqual(upload_command[:3], ["release", "upload", "core-assets-v1"])
            self.assertNotIn("--clobber", upload_command)
            self.assertIn("--repo", upload_command)
            download.assert_called_once_with(
                mirror_url,
                max_bytes=mirror.MAX_GZIP_BYTES,
            )

    def test_upload_already_exists_race_relists_and_verifies_readback(self) -> None:
        mirror = self._load_mirror_module()
        raw = b"geoip-race"
        gzipped = _stable_gzip(raw)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "GEOIP_SOURCE.txt"
            local_asset = root / "geoip.metadb.gz"
            mirror_url = _write_source_record(source, raw=raw, gzipped=gzipped)
            local_asset.write_bytes(gzipped)
            asset_name = f"geoip.metadb-{_sha256(gzipped)}.gz"
            empty = subprocess.CompletedProcess(
                args=["gh", "release", "view"],
                returncode=0,
                stdout=(
                    '{"tagName":"core-assets-v1","isDraft":false,'
                    '"isPrerelease":true,"assets":[]}'
                ),
                stderr="",
            )
            conflict = subprocess.CompletedProcess(
                args=["gh", "release", "upload"],
                returncode=1,
                stdout="",
                stderr="HTTP 422: Validation Failed (code: already_exists)",
            )
            present = subprocess.CompletedProcess(
                args=["gh", "release", "view"],
                returncode=0,
                stdout=json.dumps(
                    {
                        "tagName": "core-assets-v1",
                        "isDraft": False,
                        "isPrerelease": True,
                        "assets": [{"name": asset_name}],
                    }
                ),
                stderr="",
            )

            with patch.object(
                mirror,
                "run_gh",
                side_effect=[empty, conflict, present],
            ) as gh, patch.object(
                mirror,
                "download",
                return_value=gzipped,
            ) as download:
                mirror.ensure_mirror(
                    source_path=source,
                    local_asset=local_asset,
                    upload=True,
                )

            self.assertEqual(gh.call_count, 3)
            download.assert_called_once_with(
                mirror_url,
                max_bytes=mirror.MAX_GZIP_BYTES,
            )

    def test_successful_upload_tolerates_listing_lag_after_verified_readback(
        self,
    ) -> None:
        mirror = self._load_mirror_module()
        raw = b"geoip-listing-lag"
        gzipped = _stable_gzip(raw)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "GEOIP_SOURCE.txt"
            local_asset = root / "geoip.metadb.gz"
            _write_source_record(source, raw=raw, gzipped=gzipped)
            local_asset.write_bytes(gzipped)
            uploaded = subprocess.CompletedProcess(
                args=["gh", "release", "upload"],
                returncode=0,
                stdout="",
                stderr="",
            )

            with patch.object(
                mirror,
                "release_asset_names",
                side_effect=[set(), set()],
            ) as listings, patch.object(
                mirror,
                "run_gh",
                return_value=uploaded,
            ), patch.object(
                mirror,
                "download",
                return_value=gzipped,
            ):
                mirror.ensure_mirror(
                    source_path=source,
                    local_asset=local_asset,
                    upload=True,
                )

            self.assertEqual(listings.call_count, 2)

    def test_upload_race_fails_when_public_readback_does_not_match(self) -> None:
        mirror = self._load_mirror_module()
        raw = b"geoip-race"
        gzipped = _stable_gzip(raw)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "GEOIP_SOURCE.txt"
            local_asset = root / "geoip.metadb.gz"
            _write_source_record(source, raw=raw, gzipped=gzipped)
            local_asset.write_bytes(gzipped)
            asset_name = f"geoip.metadb-{_sha256(gzipped)}.gz"

            def release(assets: list[dict[str, str]]):
                return subprocess.CompletedProcess(
                    args=["gh", "release", "view"],
                    returncode=0,
                    stdout=json.dumps(
                        {
                            "tagName": "core-assets-v1",
                            "isDraft": False,
                            "isPrerelease": True,
                            "assets": assets,
                        }
                    ),
                    stderr="",
                )

            conflict = subprocess.CompletedProcess(
                args=["gh", "release", "upload"],
                returncode=1,
                stdout="",
                stderr="already_exists",
            )
            with patch.object(
                mirror,
                "run_gh",
                side_effect=[release([]), conflict, release([{"name": asset_name}])],
            ), patch.object(
                mirror,
                "download",
                return_value=_stable_gzip(b"attacker bytes"),
            ):
                with self.assertRaisesRegex(SystemExit, "gzip SHA256 mismatch"):
                    mirror.ensure_mirror(
                        source_path=source,
                        local_asset=local_asset,
                        upload=True,
                    )

    def test_freshness_workflow_opens_scoped_immutable_update_prs(self) -> None:
        workflow = (ROOT / ".github/workflows/maintenance.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("contents: write", workflow)
        self.assertIn("pull-requests: write", workflow)
        self.assertIn("python3 scripts/sync-geoip-metadb.py", workflow)
        self.assertNotIn("sync-geoip-metadb.py --check", workflow)
        self.assertIn("docs/GEOIP_SOURCE.txt", workflow)
        self.assertIn("git add -- docs/GEOIP_SOURCE.txt", workflow)
        self.assertIn("gh pr create", workflow)
        self.assertIn("--base main", workflow)
        self.assertIn("automation/geoip-", workflow)
        self.assertNotIn("git push --force", workflow)
        self.assertIn("timeout-minutes:", workflow)
        self.assertNotIn("scripts/bootstrap-core-assets.sh", workflow)
        sync_position = workflow.index("python3 scripts/sync-geoip-metadb.py")
        mirror_position = workflow.index(
            "python3 scripts/ensure-geoip-mirror.py --upload"
        )
        pr_position = workflow.index("gh pr create")
        self.assertLess(sync_position, mirror_position)
        self.assertLess(mirror_position, pr_position)

        mirror_script = (ROOT / "scripts/ensure-geoip-mirror.py").read_text(
            encoding="utf-8"
        )
        self.assertIn("gh", mirror_script)
        self.assertIn("release", mirror_script)
        self.assertIn("upload", mirror_script)
        self.assertNotIn("--clobber", mirror_script)

        sync_script = (ROOT / "scripts/sync-geoip-metadb.py").read_text(
            encoding="utf-8"
        )
        for path in (
            "SSRVPN_Android",
            "SSRVPN_MacOS",
            "SSRVPN_Windows",
        ):
            self.assertIn(path, sync_script)

    def test_existing_geoip_pull_request_state_policy(self) -> None:
        policy_path = ROOT / "scripts/geoip-pr-state-policy.py"
        spec = importlib.util.spec_from_file_location(
            "geoip_pr_state_policy",
            policy_path,
        )
        assert spec is not None and spec.loader is not None
        policy = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(policy)

        self.assertEqual(policy.classify_pr_state(""), "create")
        self.assertEqual(policy.classify_pr_state("OPEN"), "reuse")
        for state in ("CLOSED", "MERGED"):
            with self.subTest(state=state):
                with self.assertRaisesRegex(ValueError, state):
                    policy.classify_pr_state(state)

        workflow = (ROOT / ".github/workflows/maintenance.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn(
            'gh pr view "$BRANCH" --json state --jq .state',
            workflow,
        )
        self.assertIn(
            'python3 scripts/geoip-pr-state-policy.py "$pr_state"',
            workflow,
        )

    def test_bootstrap_uses_the_content_addressed_ssrvpn_mirror(self) -> None:
        bootstrap = (ROOT / "scripts/bootstrap-core-assets.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("geo_url=", bootstrap)
        self.assertIn("'Mirror URL'", bootstrap)
        self.assertIn("'Mirror repo'", bootstrap)
        self.assertIn("'Mirror release tag'", bootstrap)
        self.assertIn("'Mirror asset name'", bootstrap)
        self.assertIn("geo_raw_hash=", bootstrap)
        self.assertIn("'Upstream SHA256'", bootstrap)
        self.assertIn("'Bundled gzip SHA256'", bootstrap)
        self.assertIn("verify_geoip_payload", bootstrap)
        self.assertIn(
            "https://github.com/Elegying/SSRVPN/releases/download/core-assets-v1/",
            bootstrap,
        )
        self.assertNotIn("gzip.compress(raw, compresslevel=9, mtime=0)", bootstrap)
        self.assertIn("https://api.github.com/*", bootstrap)
        self.assertIn("Accept: application/octet-stream", bootstrap)
        self.assertIn(
            '[[ "$url" == https://api.github.com/* && -n "${GITHUB_TOKEN:-}" ]]',
            bootstrap,
        )
        self.assertIn('--oauth2-bearer "${GITHUB_TOKEN}"', bootstrap)
        self.assertNotIn("Authorization: Bearer ${GITHUB_TOKEN}", bootstrap)
        self.assertIn("--max-filesize", bootstrap)
        self.assertIn("extract_zip_member_bounded", bootstrap)
        self.assertIn("info.file_size", bootstrap)
        self.assertIn("source.read", bootstrap)
        self.assertNotIn("geo_member=", bootstrap)

        sync_script = (ROOT / "scripts/sync-geoip-metadb.py").read_text(
            encoding="utf-8"
        )
        self.assertIn("asset.get('url', '')", sync_script)
        self.assertIn("Asset ID:", sync_script)

    def test_curl_oauth_token_is_not_forwarded_to_a_redirect_host(self) -> None:
        initial_authorization: list[str | None] = []
        redirected_authorization: list[str | None] = []

        class RedirectTarget(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                redirected_authorization.append(self.headers.get("Authorization"))
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b"ok")

            def log_message(self, *_args) -> None:
                pass

        target = ThreadingHTTPServer(("127.0.0.1", 0), RedirectTarget)

        class InitialHost(BaseHTTPRequestHandler):
            def do_GET(self) -> None:
                initial_authorization.append(self.headers.get("Authorization"))
                self.send_response(302)
                self.send_header(
                    "Location",
                    f"http://127.0.0.1:{target.server_port}/asset",
                )
                self.end_headers()

            def log_message(self, *_args) -> None:
                pass

        initial = ThreadingHTTPServer(("127.0.0.1", 0), InitialHost)
        target_thread = threading.Thread(target=target.serve_forever, daemon=True)
        initial_thread = threading.Thread(target=initial.serve_forever, daemon=True)
        target_thread.start()
        initial_thread.start()
        try:
            subprocess.run(
                [
                    "curl",
                    "--fail",
                    "--silent",
                    "--show-error",
                    "--location",
                    "--oauth2-bearer",
                    "test-token",
                    f"http://localhost:{initial.server_port}/asset",
                ],
                check=True,
                stdout=subprocess.DEVNULL,
            )
        finally:
            initial.shutdown()
            target.shutdown()
            initial.server_close()
            target.server_close()
            initial_thread.join(timeout=5)
            target_thread.join(timeout=5)

        self.assertEqual(initial_authorization, ["Bearer test-token"])
        self.assertEqual(redirected_authorization, [None])


if __name__ == "__main__":
    unittest.main()
