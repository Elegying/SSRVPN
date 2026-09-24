#!/usr/bin/env python3
"""Retain hash-pinned test baselines before retiring client Release listings."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
GITHUB_BASE = "https://github.com/Elegying/SSRVPN/releases/download"
ARCHIVE_BASE = "https://nikuaimobi.oss-cn-qingdao.aliyuncs.com/ssrvpn/releases"
OBJECT_BASE = "oss://nikuaimobi/ssrvpn/releases"


def load_sources():
    sources = json.loads(
        (ROOT / "scripts/windows_legacy_installer_sources.json").read_text(encoding="utf-8")
    )
    seen = set()
    for source in sources:
        tag = source["tag"]
        if not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag) or tag in seen:
            raise ValueError("Invalid or duplicate historical tag")
        seen.add(tag)
        if not re.fullmatch(r"[0-9a-f]{64}", source["sha256"]):
            raise ValueError("Invalid baseline SHA-256")
        suffix = f"/{tag}/SSRVPN_Setup.exe"
        if source["url"] != ARCHIVE_BASE + suffix:
            raise ValueError("Unexpected archive destination")
        if source["originalUrl"] != GITHUB_BASE + suffix:
            raise ValueError("Unexpected original source")
    if not sources:
        raise ValueError("Empty historical baseline list")
    return sources


def fetch(url, target):
    result = subprocess.run(
        [
            "curl", "-q", "--silent", "--show-error", "--location",
            "--proto", "=https", "--proto-redir", "=https",
            "--retry", "3", "--connect-timeout", "10", "--max-time", "180",
            "--max-filesize", "134217728", "--output", str(target),
            "--write-out", "%{http_code}", url,
        ],
        check=True, capture_output=True, text=True,
    )
    if result.stdout == "404":
        return False
    if result.stdout != "200":
        raise RuntimeError(f"Baseline download returned HTTP {result.stdout}")
    return True


def verify(path, expected):
    with path.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest()
    if actual != expected:
        raise ValueError("Historical installer SHA-256 mismatch; no overwrite allowed")


def archive_one(source, directory, upload):
    target = directory / "archive.exe"
    if fetch(source["url"], target):
        verify(target, source["sha256"])
        action = "verified-existing"
    else:
        if not upload:
            raise RuntimeError(f"Missing archive for {source['tag']}")
        original = directory / "original.exe"
        if not fetch(source["originalUrl"], original):
            raise RuntimeError(f"Missing original baseline for {source['tag']}")
        verify(original, source["sha256"])
        # Match the release workflow's immutable-object policy. A concurrent
        # creation is accepted only after anonymous readback verifies its bytes.
        subprocess.run(
            ["ossutil", "cp", str(original),
             f"{OBJECT_BASE}/{source['tag']}/SSRVPN_Setup.exe", "--ignore-existing"],
            check=True,
        )
        if not fetch(source["url"], target):
            raise RuntimeError("Uploaded baseline is not publicly readable")
        verify(target, source["sha256"])
        action = "archived-and-verified"
    return {
        "tag": source["tag"], "url": source["url"], "originalUrl": source["originalUrl"],
        "sha256": source["sha256"], "bytes": target.stat().st_size, "action": action,
    }


def require_upload_environment():
    expected = {
        "GITHUB_ACTIONS": "true", "GITHUB_REPOSITORY": "Elegying/SSRVPN",
        "GITHUB_REF": "refs/heads/main", "GITHUB_EVENT_NAME": "workflow_dispatch",
        "OSS_BUCKET": "nikuaimobi", "OSS_ENDPOINT": "oss-cn-qingdao.aliyuncs.com",
        "OSS_PREFIX": "ssrvpn",
    }
    for name, value in expected.items():
        if os.environ.get(name) != value:
            raise RuntimeError(f"Archive upload requires the configured main maintenance job: {name}")
    for name in ("OSS_ACCESS_KEY_ID", "OSS_ACCESS_KEY_SECRET"):
        if not os.environ.get(name):
            raise RuntimeError(f"Missing archive credential: {name}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upload", action="store_true", help="Fill missing archives; main maintenance only")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    if args.upload:
        require_upload_environment()
    sources = load_sources()
    results = []
    args.report.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="ssrvpn-baselines-") as temporary:
        for source in sources:
            result = archive_one(source, Path(temporary), args.upload)
            results.append(result)
            args.report.write_text(json.dumps(results, indent=2) + "\n", encoding="utf-8")
            print(f"{result['tag']}: {result['action']} ({result['sha256']})", flush=True)


if __name__ == "__main__":
    main()
