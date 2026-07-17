import importlib.util
import os
import unittest
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
        self.assertIn("--max-filesize", bootstrap)
        self.assertNotIn("geo_member=", bootstrap)

        sync_script = (ROOT / "scripts/sync-geoip-metadb.py").read_text(
            encoding="utf-8"
        )
        self.assertIn("asset.get('url', '')", sync_script)
        self.assertIn("Asset ID:", sync_script)


if __name__ == "__main__":
    unittest.main()
