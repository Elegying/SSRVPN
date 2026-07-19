#!/usr/bin/env python3
from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import shutil
import subprocess
import tempfile
import time
import urllib.request
from io import BytesIO
from pathlib import Path
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
SOURCE_RECORD = ROOT / "docs/GEOIP_SOURCE.txt"
LOCAL_ASSETS = [
    ROOT / "SSRVPN_Android/assets/geoip.metadb.gz",
    ROOT / "SSRVPN_MacOS/assets/geoip.metadb.gz",
    ROOT / "SSRVPN_Windows/assets/geoip.metadb.gz",
]
MIRROR_REPO = "Elegying/SSRVPN"
MIRROR_RELEASE_TAG = "core-assets-v1"
MIRROR_URL_PREFIX = (
    "https://github.com/Elegying/SSRVPN/releases/download/core-assets-v1/"
)
MAX_GZIP_BYTES = 64 * 1024 * 1024
MAX_RAW_BYTES = 64 * 1024 * 1024
MAX_DOWNLOAD_SECONDS = 60
DOWNLOAD_CHUNK_BYTES = 64 * 1024
ALLOWED_MIRROR_DOWNLOAD_HOSTS = frozenset(
    {
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com",
    }
)


def validate_download_url(url: str) -> None:
    parsed = urlsplit(url)
    try:
        port = parsed.port
    except ValueError as error:
        raise SystemExit(
            f"GeoIP mirror URL is not an approved GitHub HTTPS download host: {url}"
        ) from error
    if (
        parsed.scheme != "https"
        or parsed.hostname not in ALLOWED_MIRROR_DOWNLOAD_HOSTS
        or port not in (None, 443)
        or parsed.username is not None
        or parsed.password is not None
    ):
        raise SystemExit(
            f"GeoIP mirror URL is not an approved GitHub HTTPS download host: {url}"
        )


class MirrorRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        req,
        fp,
        code,
        msg,
        headers,
        newurl,
    ):
        validate_download_url(newurl)
        redirected = super().redirect_request(
            req,
            fp,
            code,
            msg,
            headers,
            newurl,
        )
        if redirected is not None:
            for name in ("Authorization", "Proxy-Authorization", "Cookie"):
                redirected.remove_header(name)
        return redirected


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def require_sha256(value: str, field: str) -> str:
    if len(value) != 64 or any(
        character not in "0123456789abcdef" for character in value
    ):
        raise SystemExit(f"{field} must be a lowercase SHA256")
    return value


def read_source_record(path: Path) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise SystemExit(f"cannot read GeoIP source record {path}: {error}") from error

    fields: dict[str, str] = {}
    for line_number, line in enumerate(lines, start=1):
        if not line:
            continue
        if ": " not in line:
            raise SystemExit(
                f"malformed GeoIP source record line {line_number}: {line}"
            )
        name, value = line.split(": ", 1)
        if not name or not value:
            raise SystemExit(f"empty GeoIP source record field on line {line_number}")
        if name in fields:
            raise SystemExit(f"duplicate GeoIP source record field: {name}")
        fields[name] = value
    return fields


def require_field(fields: dict[str, str], name: str) -> str:
    value = fields.get(name, "")
    if not value:
        raise SystemExit(f"GeoIP source record is missing {name}")
    return value


def validate_mirror_url(url: str, asset_name: str) -> None:
    expected = f"{MIRROR_URL_PREFIX}{asset_name}"
    if url != expected:
        raise SystemExit(
            "GeoIP Mirror URL is not the approved GeoIP mirror "
            f"{MIRROR_REPO}@{MIRROR_RELEASE_TAG}: {url}"
        )


def load_source_spec(path: Path) -> dict[str, str]:
    fields = read_source_record(path)
    raw_hash = require_sha256(
        require_field(fields, "Upstream SHA256"),
        "Upstream SHA256",
    )
    gzip_hash = require_sha256(
        require_field(fields, "Bundled gzip SHA256"),
        "Bundled gzip SHA256",
    )
    repo = require_field(fields, "Mirror repo")
    release_tag = require_field(fields, "Mirror release tag")
    asset_name = require_field(fields, "Mirror asset name")
    mirror_url = require_field(fields, "Mirror URL")
    expected_name = f"geoip.metadb-{gzip_hash}.gz"

    if repo != MIRROR_REPO or release_tag != MIRROR_RELEASE_TAG:
        raise SystemExit(
            "GeoIP mirror must use the approved support release "
            f"{MIRROR_REPO}@{MIRROR_RELEASE_TAG}"
        )
    if asset_name != expected_name:
        raise SystemExit(
            f"GeoIP mirror asset must be content-addressed as {expected_name}"
        )
    validate_mirror_url(mirror_url, asset_name)
    return {
        "raw_hash": raw_hash,
        "gzip_hash": gzip_hash,
        "asset_name": asset_name,
        "mirror_url": mirror_url,
    }


def verify_payload(
    payload: bytes,
    *,
    expected_gzip_hash: str,
    expected_raw_hash: str,
) -> None:
    if len(payload) > MAX_GZIP_BYTES:
        raise SystemExit(f"GeoIP mirror gzip exceeds the {MAX_GZIP_BYTES} byte limit")
    actual_gzip_hash = sha256(payload)
    if actual_gzip_hash != expected_gzip_hash:
        raise SystemExit(
            "GeoIP mirror gzip SHA256 mismatch: "
            f"expected {expected_gzip_hash}, got {actual_gzip_hash}"
        )

    digest = hashlib.sha256()
    total = 0
    try:
        with gzip.GzipFile(fileobj=BytesIO(payload), mode="rb") as source:
            while True:
                chunk = source.read(
                    min(DOWNLOAD_CHUNK_BYTES, MAX_RAW_BYTES + 1 - total)
                )
                if not chunk:
                    break
                total += len(chunk)
                if total > MAX_RAW_BYTES:
                    raise SystemExit(
                        f"GeoIP mirror raw payload exceeds the {MAX_RAW_BYTES} byte limit"
                    )
                digest.update(chunk)
    except (EOFError, OSError) as error:
        raise SystemExit(f"GeoIP mirror is not a valid gzip: {error}") from error

    actual_raw_hash = digest.hexdigest()
    if actual_raw_hash != expected_raw_hash:
        raise SystemExit(
            "GeoIP mirror raw SHA256 mismatch: "
            f"expected {expected_raw_hash}, got {actual_raw_hash}"
        )


def download(url: str, *, max_bytes: int) -> bytes:
    validate_download_url(url)
    deadline = time.monotonic() + MAX_DOWNLOAD_SECONDS
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "application/octet-stream",
            "User-Agent": "SSRVPN-geoip-mirror-verifier",
        },
    )
    opener = urllib.request.build_opener(MirrorRedirectHandler())
    with opener.open(request, timeout=10) as response:
        content_length = response.headers.get("Content-Length")
        if content_length is not None:
            try:
                declared_size = int(content_length)
            except ValueError as error:
                raise SystemExit(
                    f"GeoIP mirror returned an invalid Content-Length: {content_length}"
                ) from error
            if declared_size > max_bytes:
                raise SystemExit(
                    f"GeoIP mirror exceeds the {max_bytes} byte limit: {url}"
                )

        content = bytearray()
        read_chunk = response.read1 if hasattr(response, "read1") else response.read
        while True:
            if time.monotonic() >= deadline:
                raise SystemExit("GeoIP mirror download exceeded its absolute deadline")
            chunk = read_chunk(
                min(DOWNLOAD_CHUNK_BYTES, max_bytes + 1 - len(content))
            )
            if not chunk:
                break
            content.extend(chunk)
            if len(content) > max_bytes:
                raise SystemExit(
                    f"GeoIP mirror exceeds the {max_bytes} byte limit: {url}"
                )
            if time.monotonic() >= deadline:
                raise SystemExit("GeoIP mirror download exceeded its absolute deadline")
    return bytes(content)


def run_gh(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    if shutil.which("gh") is None:
        raise SystemExit("GitHub CLI (gh) is required to manage the GeoIP mirror")
    try:
        return subprocess.run(
            ["gh", *arguments],
            text=True,
            capture_output=True,
            check=False,
            timeout=60,
        )
    except subprocess.TimeoutExpired as error:
        raise SystemExit("GitHub CLI timed out while managing the GeoIP mirror") from error


def release_asset_names() -> set[str]:
    result = run_gh(
        [
            "release",
            "view",
            MIRROR_RELEASE_TAG,
            "--repo",
            MIRROR_REPO,
            "--json",
            "tagName,isDraft,isPrerelease,assets",
        ]
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or "release not found"
        raise SystemExit(
            "GeoIP mirror support release "
            f"{MIRROR_REPO}@{MIRROR_RELEASE_TAG} is missing or inaccessible: {detail}"
        )
    try:
        metadata = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise SystemExit("GitHub CLI returned invalid GeoIP mirror release JSON") from error
    if metadata.get("tagName") != MIRROR_RELEASE_TAG:
        raise SystemExit(
            f"GeoIP mirror release tag does not match {MIRROR_RELEASE_TAG}"
        )
    if (
        metadata.get("isDraft") is not False
        or metadata.get("isPrerelease") is not True
    ):
        raise SystemExit(
            "GeoIP mirror support release must be a published prerelease so it "
            "cannot become the application's latest release"
        )
    assets = metadata.get("assets")
    if not isinstance(assets, list):
        raise SystemExit("GeoIP mirror release JSON does not contain an asset list")
    return {
        str(asset["name"])
        for asset in assets
        if isinstance(asset, dict) and isinstance(asset.get("name"), str)
    }


def ensure_mirror(
    *,
    source_path: Path,
    local_asset: Path,
    upload: bool,
) -> None:
    spec = load_source_spec(source_path)
    try:
        local_payload = local_asset.read_bytes()
    except OSError as error:
        raise SystemExit(f"cannot read local GeoIP gzip {local_asset}: {error}") from error
    verify_payload(
        local_payload,
        expected_gzip_hash=spec["gzip_hash"],
        expected_raw_hash=spec["raw_hash"],
    )

    asset_names = release_asset_names()
    asset_name = spec["asset_name"]
    if asset_name not in asset_names:
        if not upload:
            raise SystemExit(
                "GeoIP mirror asset is missing; run ensure-geoip-mirror.py --upload "
                f"after reviewing {source_path}"
            )
        with tempfile.TemporaryDirectory(prefix="ssrvpn-geoip-mirror-") as temp:
            upload_path = Path(temp) / asset_name
            upload_path.write_bytes(local_payload)
            result = run_gh(
                [
                    "release",
                    "upload",
                    MIRROR_RELEASE_TAG,
                    str(upload_path),
                    "--repo",
                    MIRROR_REPO,
                ]
            )
        upload_output = f"{result.stdout}\n{result.stderr}".lower()
        already_exists = (
            "already_exists" in upload_output or "already exists" in upload_output
        )
        if result.returncode != 0 and not already_exists:
            detail = result.stderr.strip() or "upload failed"
            raise SystemExit(
                f"GeoIP mirror upload failed without overwrite: {detail}"
            )

        # A competing freshness run can publish the same content-addressed name
        # between list and upload. Re-list for auditability, but treat the public
        # URL plus both hashes as authoritative because GitHub's listing can lag.
        refreshed_names = release_asset_names()
        if asset_name not in refreshed_names:
            print(
                "GeoIP mirror: asset listing has not converged; verifying the "
                f"public content-addressed URL for {asset_name}"
            )
        elif already_exists:
            print(f"GeoIP mirror: concurrent upload already published {asset_name}")
        else:
            print(f"GeoIP mirror: uploaded content-addressed asset {asset_name}")
    else:
        print(f"GeoIP mirror: content-addressed asset already exists {asset_name}")

    readback = download(spec["mirror_url"], max_bytes=MAX_GZIP_BYTES)
    verify_payload(
        readback,
        expected_gzip_hash=spec["gzip_hash"],
        expected_raw_hash=spec["raw_hash"],
    )
    print(f"GeoIP mirror: verified read-back {spec['mirror_url']}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Ensure the content-addressed GeoIP gzip exists in SSRVPN's support "
            "release and verify it through the public bootstrap URL."
        )
    )
    parser.add_argument(
        "--upload",
        action="store_true",
        help="Upload a missing content-addressed asset without replacing existing assets.",
    )
    parser.add_argument(
        "--source",
        type=Path,
        default=SOURCE_RECORD,
        help="GeoIP provenance source record.",
    )
    args = parser.parse_args()

    spec = load_source_spec(args.source)
    for local_asset in LOCAL_ASSETS:
        try:
            payload = local_asset.read_bytes()
        except OSError as error:
            raise SystemExit(
                f"cannot read synchronized GeoIP gzip {local_asset}: {error}"
            ) from error
        verify_payload(
            payload,
            expected_gzip_hash=spec["gzip_hash"],
            expected_raw_hash=spec["raw_hash"],
        )
    ensure_mirror(
        source_path=args.source,
        local_asset=LOCAL_ASSETS[0],
        upload=args.upload,
    )


if __name__ == "__main__":
    main()
