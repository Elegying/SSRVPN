from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("validate-existing-release-retry.py")
SPEC = importlib.util.spec_from_file_location("release_retry", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


COMMIT = "b" * 40


def release(
    *,
    missing: str | None = None,
    prerelease: bool = False,
    draft: bool = False,
) -> dict:
    assets = []
    for name in sorted(MODULE.REQUIRED_ASSETS):
        if name == missing:
            continue
        assets.append(
            {
                "name": name,
                "size": 64 if name.endswith(".sha256") else 1024,
                "digest": "sha256:" + "a" * 64,
            }
        )
    return {"draft": draft, "prerelease": prerelease, "assets": assets}


def provenance(**overrides: object) -> dict:
    result = {
        "schema": 1,
        "tag": "v3.2.0",
        "commit": COMMIT,
        "assets": {name: "a" * 64 for name in MODULE.CANONICAL_BINARIES},
    }
    result.update(overrides)
    return result


class ExistingReleaseRetryTest(unittest.TestCase):
    def test_complete_verified_public_release_can_resume_after_main_advances(self) -> None:
        MODULE.validate_release_metadata(
            release(), provenance(), expected_tag="v3.2.0", expected_commit=COMMIT
        )

    def test_draft_release_cannot_authorize_stale_source_retry(self) -> None:
        with self.assertRaisesRegex(ValueError, "draft"):
            MODULE.validate_release_metadata(
                release(draft=True),
                provenance(),
                expected_tag="v3.2.0",
                expected_commit=COMMIT,
            )

    def test_empty_or_partial_draft_cannot_bypass_main_tip(self) -> None:
        with self.assertRaisesRegex(ValueError, "incomplete"):
            MODULE.validate_release_metadata(
                release(missing="SSRVPN.dmg"),
                provenance(),
                expected_tag="v3.2.0",
                expected_commit=COMMIT,
            )

    def test_prerelease_cannot_enter_the_stable_retry_path(self) -> None:
        with self.assertRaisesRegex(ValueError, "prerelease"):
            MODULE.validate_release_metadata(
                release(prerelease=True),
                provenance(),
                expected_tag="v3.2.0",
                expected_commit=COMMIT,
            )

    def test_oversized_asset_is_rejected(self) -> None:
        data = release()
        data["assets"][0]["size"] = 10**12
        with self.assertRaisesRegex(ValueError, "invalid size"):
            MODULE.validate_release_metadata(
                data, provenance(), expected_tag="v3.2.0", expected_commit=COMMIT
            )

    def test_missing_github_digest_is_rejected(self) -> None:
        data = release()
        data["assets"][0]["digest"] = None
        with self.assertRaisesRegex(ValueError, "trusted digest"):
            MODULE.validate_release_metadata(
                data, provenance(), expected_tag="v3.2.0", expected_commit=COMMIT
            )

    def test_provenance_must_bind_the_exact_tag_commit_and_hashes(self) -> None:
        for bad in (
            provenance(tag="v3.1.0"),
            provenance(commit="c" * 40),
            provenance(assets={"SSRVPN.apk": "0" * 64}),
        ):
            with self.assertRaisesRegex(ValueError, "provenance"):
                MODULE.validate_release_metadata(
                    release(),
                    bad,
                    expected_tag="v3.2.0",
                    expected_commit=COMMIT,
                )


if __name__ == "__main__":
    unittest.main()
