from __future__ import annotations

import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("generate-release-provenance.py")
SPEC = importlib.util.spec_from_file_location("release_provenance", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class GenerateReleaseProvenanceTest(unittest.TestCase):
    def test_binds_asset_hashes_to_tag_and_commit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            asset = Path(directory, "SSRVPN.apk")
            asset.write_bytes(b"apk")
            result = MODULE.build_provenance("v3.2.0", "a" * 40, [asset])
        self.assertEqual(result["schema"], 1)
        self.assertEqual(result["tag"], "v3.2.0")
        self.assertEqual(result["commit"], "a" * 40)
        self.assertEqual(
            result["assets"],
            {"SSRVPN.apk": hashlib.sha256(b"apk").hexdigest()},
        )

    def test_rejects_invalid_tag_or_commit(self) -> None:
        with self.assertRaisesRegex(ValueError, "invalid release tag"):
            MODULE.build_provenance("latest", "a" * 40, [])
        with self.assertRaisesRegex(ValueError, "40-character"):
            MODULE.build_provenance("v3.2.0", "short", [])


if __name__ == "__main__":
    unittest.main()
