import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class GeoIpWorkflowTest(unittest.TestCase):
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
        self.assertNotIn("geo_member=", bootstrap)

        sync_script = (ROOT / "scripts/sync-geoip-metadb.py").read_text(
            encoding="utf-8"
        )
        self.assertIn("asset.get('url', '')", sync_script)
        self.assertIn("Asset ID:", sync_script)


if __name__ == "__main__":
    unittest.main()
