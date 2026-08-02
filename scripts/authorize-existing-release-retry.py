#!/usr/bin/env python3
"""Authorize reuse of an already complete GitHub Release without mutating it."""

from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path


MISSING_RELEASE_EXIT = 3
TRANSIENT_ERROR = re.compile(
    r"HTTP (408|429|500|502|503|504)|rate.?limit|timed? ?out|timeout|"
    r"connection (reset|refused)|temporar(il)?y unavailable|TLS handshake|"
    r"unexpected EOF",
    re.IGNORECASE,
)
NOT_FOUND_ERROR = re.compile(r"HTTP 404|Not Found.*404|404.*Not Found")


def load_validator():
    path = Path(__file__).with_name("validate-existing-release-retry.py")
    spec = importlib.util.spec_from_file_location("existing_release_retry", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load the existing release retry validator")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class GithubApiError(RuntimeError):
    def __init__(self, stderr: str):
        super().__init__(stderr.strip() or "GitHub API request failed")
        self.stderr = stderr


def github_api(*args: str) -> bytes:
    attempts_raw = os.environ.get("GITHUB_API_RETRY_ATTEMPTS", "4")
    delay_raw = os.environ.get("GITHUB_API_RETRY_BASE_SECONDS", "1")
    if not attempts_raw.isdigit() or not 1 <= int(attempts_raw) <= 10:
        raise ValueError("GITHUB_API_RETRY_ATTEMPTS must be between 1 and 10")
    if not delay_raw.isdigit() or not 0 <= int(delay_raw) <= 30:
        raise ValueError("GITHUB_API_RETRY_BASE_SECONDS must be between 0 and 30")
    max_attempts = int(attempts_raw)
    base_delay = int(delay_raw)

    for attempt in range(1, max_attempts + 1):
        try:
            result = subprocess.run(
                ["gh", "api", *args],
                capture_output=True,
                check=False,
                timeout=30,
            )
        except subprocess.TimeoutExpired as error:
            stderr = f"GitHub API request timed out after {error.timeout}s"
        else:
            if result.returncode == 0:
                return result.stdout
            stderr = result.stderr.decode("utf-8", errors="replace")
        if attempt == max_attempts or TRANSIENT_ERROR.search(stderr) is None:
            raise GithubApiError(stderr)
        delay = min(base_delay * (1 << (attempt - 1)), 30)
        print(
            f"Transient GitHub API failure (attempt {attempt}/{max_attempts}); "
            f"retrying in {delay}s",
            file=sys.stderr,
        )
        time.sleep(delay)
    raise AssertionError("unreachable")


def parse_json(payload: bytes, label: str) -> object:
    try:
        return json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{label} is not valid JSON") from error


def find_release(
    repo: str,
    tag: str,
    expected_release_id: int | None = None,
) -> dict[str, object] | None:
    if expected_release_id is not None:
        payload = github_api(f"repos/{repo}/releases/{expected_release_id}")
        release = parse_json(payload, "GitHub release response")
        if not isinstance(release, dict):
            raise ValueError("GitHub release response is not an object")
        return release

    try:
        payload = github_api(f"repos/{repo}/releases/tags/{tag}")
    except GithubApiError as error:
        if NOT_FOUND_ERROR.search(error.stderr) is None:
            raise
        payload = github_api(
            "--paginate",
            "--slurp",
            f"repos/{repo}/releases?per_page=100",
        )
        pages = parse_json(payload, "GitHub paginated release response")
        if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
            raise ValueError("GitHub paginated release response is invalid")
        matches = [
            release
            for page in pages
            for release in page
            if isinstance(release, dict) and release.get("tag_name") == tag
        ]
        if not matches:
            return None
        if len(matches) != 1:
            raise ValueError(f"Multiple GitHub releases use tag {tag}")
        return matches[0]

    release = parse_json(payload, "GitHub release response")
    if not isinstance(release, dict):
        raise ValueError("GitHub release response is not an object")
    return release


def authorize(
    repo: str,
    tag: str,
    commit: str,
    work_dir: Path,
    expected_release_id: int | None = None,
) -> dict[str, object] | None:
    validator = load_validator()
    release = find_release(repo, tag, expected_release_id)
    if release is None:
        return None

    assets = validator.validate_release_asset_metadata(release, expected_tag=tag)
    provenance_asset = assets["SSRVPN-release-provenance.json"]
    provenance_id = provenance_asset["id"]
    provenance = github_api(
        "-H",
        "Accept: application/octet-stream",
        f"repos/{repo}/releases/assets/{provenance_id}",
    )
    validator.validate_downloaded_asset_digest(
        release,
        "SSRVPN-release-provenance.json",
        provenance,
    )
    provenance_data = parse_json(provenance, "release provenance")
    validator.validate_release_metadata(
        release,
        provenance_data,
        expected_tag=tag,
        expected_commit=commit,
    )

    work_dir.mkdir(parents=True, exist_ok=True)
    (work_dir / "release.json").write_text(
        json.dumps(release, sort_keys=True), encoding="utf-8"
    )
    (work_dir / "SSRVPN-release-provenance.json").write_bytes(provenance)
    return release


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--work-dir", required=True, type=Path)
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--expected-release-id", type=int)
    parser.add_argument("--expected-release-identity")
    args = parser.parse_args()
    try:
        has_expected_id = args.expected_release_id is not None
        has_expected_identity = args.expected_release_identity is not None
        if has_expected_id != has_expected_identity:
            raise ValueError("expected release ID and identity must be provided together")
        if has_expected_id and args.expected_release_id <= 0:
            raise ValueError("expected release ID must be positive")
        if has_expected_identity and re.fullmatch(
            r"[0-9a-f]{64}", args.expected_release_identity
        ) is None:
            raise ValueError("expected release identity is invalid")

        release = authorize(
            args.repo,
            args.tag,
            args.commit,
            args.work_dir,
            args.expected_release_id,
        )
        if release is None:
            print(f"No existing GitHub release found for {args.tag}.")
            return MISSING_RELEASE_EXIT
        validator = load_validator()
        identity = validator.release_identity_digest(
            release,
            expected_tag=args.tag,
        )
        if has_expected_id and release.get("id") != args.expected_release_id:
            raise ValueError("GitHub release ID does not match the authorized retry")
        if has_expected_identity and identity != args.expected_release_identity:
            raise ValueError("GitHub release identity does not match the authorized retry")
        if args.github_output is not None:
            with args.github_output.open("a", encoding="utf-8") as output:
                output.write(f"release_id={release['id']}\n")
                output.write(f"release_identity={identity}\n")
    except (GithubApiError, OSError, ValueError) as error:
        print(f"Existing release retry validation failed: {error}", file=sys.stderr)
        return 1
    print(f"Validated existing release retry for {args.tag}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
