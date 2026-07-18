import importlib.util
import os
import subprocess
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "sync_geoip_metadb",
    ROOT / "scripts/sync-geoip-metadb.py",
)
assert SPEC is not None and SPEC.loader is not None
SYNC = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SYNC)


class _FakeResponse(BytesIO):
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

    def test_freshness_workflow_opens_scoped_immutable_update_prs(self) -> None:
        workflow = (ROOT / ".github/workflows/geoip-check.yml").read_text(
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

        sync_script = (ROOT / "scripts/sync-geoip-metadb.py").read_text(
            encoding="utf-8"
        )
        for path in (
            "SSRVPN_Android",
            "SSRVPN_MacOS",
            "SSRVPN_Windows",
        ):
            self.assertIn(path, sync_script)

    def test_bootstrap_uses_the_pinned_upstream_asset(self) -> None:
        bootstrap = (ROOT / "scripts/bootstrap-core-assets.sh").read_text(
            encoding="utf-8"
        )

        self.assertIn("geo_url=", bootstrap)
        self.assertIn("'Asset URL'", bootstrap)
        self.assertIn("geo_raw_hash=", bootstrap)
        self.assertIn("'Upstream SHA256'", bootstrap)
        self.assertIn("gzip.compress(raw, compresslevel=9, mtime=0)", bootstrap)
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
