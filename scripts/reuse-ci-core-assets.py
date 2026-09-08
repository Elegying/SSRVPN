#!/usr/bin/env python3
"""Restore pinned cores from a verified exact-main CI; exit 3 only if unavailable."""

import argparse
from datetime import datetime, timedelta, timezone
import hashlib
import importlib.util
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "main_ci", ROOT / "scripts/find-reusable-main-ci.py"
)
CI = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CI)
MAX_BYTES = 256 * 1024 * 1024
MAX_AGE = timedelta(hours=24)
ASSETS = {
    "SSRVPN_Android/android/app/src/main/jniLibs/arm64-v8a/libgojni.so":
        ("SSRVPN_Android/assets/libgojni-source.txt", "Library SHA256"),
    "SSRVPN_MacOS/assets/AtlasCore.gz":
        ("SSRVPN_MacOS/assets/AtlasCore-source.txt", "Bundled gzip SHA256"),
    "SSRVPN_Windows/assets/mihomo.exe":
        ("SSRVPN_Windows/assets/mihomo-source.txt", "Executable SHA256"),
    **{f"{platform}/assets/geoip.metadb.gz":
       ("docs/GEOIP_SOURCE.txt", "Bundled gzip SHA256")
       for platform in ("SSRVPN_Android", "SSRVPN_MacOS", "SSRVPN_Windows")},
}


def trusted_run(repo, sha, run_id, now):
    workflow_id = CI.canonical_workflow_id(repo)
    if run_id is None:
        runs = CI.paginated_items(
            f"repos/{repo}/actions/workflows/{workflow_id}/runs", "workflow_runs",
            (("branch", "main"), ("head_sha", sha), ("exclude_pull_requests", "true")),
        )
        if not runs:
            return None
        run_id = max(runs, key=lambda run: CI.parse_timestamp(
            run.get("created_at"), "run.created_at"))["id"]
    # Re-read the exact run rather than trusting a possibly stale list response.
    run = CI.gh_api_json(f"repos/{repo}/actions/runs/{run_id}")
    if not isinstance(run, dict) or run.get("id") != run_id:
        raise CI.VerificationError("CI run identity changed")
    state, created_at = CI.eligible_run(
        run, repo=repo, sha=sha, workflow_id=workflow_id, now=now,
        max_age=timedelta.max,
    )
    if state != "reusable":
        raise CI.VerificationError("exact-main CI identity or conclusion is not reusable")
    if now - created_at > MAX_AGE:
        return None
    jobs = CI.paginated_items(
        f"repos/{repo}/actions/runs/{run_id}/jobs", "jobs", (("filter", "latest"),),
    )
    passed, reason = CI.required_jobs_succeeded(
        jobs, run_id=run_id, sha=sha,
        required_names=CI.load_required_names(ROOT / ".github/main-branch-protection.json"),
    )
    if not passed:
        raise CI.VerificationError(reason)
    return run


def validate_artifact(artifact, run, repo, now):
    artifact_id = CI.positive_int(artifact.get("id"), "artifact.id")
    identity = artifact.get("workflow_run")
    if not isinstance(identity, dict) or any(
        identity.get(field) != expected for field, expected in (
            ("id", run["id"]), ("head_sha", run["head_sha"]), ("head_branch", "main"),
            ("repository_id", CI.positive_int(run["repository"].get("id"), "repository.id")),
            ("head_repository_id", CI.positive_int(run["head_repository"].get("id"), "head_repository.id")),
        )
    ):
        raise CI.VerificationError("core artifact does not belong to the verified run")
    endpoint = f"repos/{repo}/actions/artifacts/{artifact_id}"
    if (artifact.get("name") != "core-assets" or
            artifact.get("url") != f"https://api.github.com/{endpoint}" or
            artifact.get("archive_download_url") != f"https://api.github.com/{endpoint}/zip"):
        raise CI.VerificationError("core artifact name or endpoint changed")
    if CI.positive_int(artifact.get("size_in_bytes"), "artifact size") > MAX_BYTES:
        raise CI.VerificationError("core artifact exceeds size limit")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest") or ""):
        raise CI.VerificationError("core artifact has no valid SHA-256 digest")
    if not isinstance(artifact.get("expired"), bool):
        raise CI.VerificationError("artifact expiry flag is malformed")
    expiry = CI.parse_timestamp(artifact.get("expires_at"), "artifact.expires_at")
    return not artifact["expired"] and expiry > now


def download_archive(repo, artifact_id, output):
    # gh owns authenticated GitHub redirects; never forward the token ourselves.
    with tempfile.TemporaryFile() as errors, output.open("wb") as target:
        process = subprocess.Popen(
            ["gh", "api", f"repos/{repo}/actions/artifacts/{artifact_id}/zip"],
            stdout=subprocess.PIPE, stderr=errors,
        )
        try:
            total = 0
            while chunk := process.stdout.read(1024 * 1024):
                total += len(chunk)
                if total > MAX_BYTES:
                    raise CI.VerificationError("downloaded artifact exceeds size limit")
                target.write(chunk)
            if process.wait() != 0:
                raise CI.VerificationError("could not download verified core artifact")
        finally:
            if process.poll() is None:
                process.kill()
            process.wait()
            process.stdout.close()


def install_archive(archive, artifact, root):
    root = root.resolve()
    if archive.stat().st_size != artifact["size_in_bytes"]:
        raise CI.VerificationError("core artifact archive size mismatch")
    if file_digest(archive) != artifact["digest"][7:]:
        raise CI.VerificationError("core artifact archive SHA-256 mismatch")
    expected = {}
    for name, (record, field) in ASSETS.items():
        values = [line.removeprefix(f"{field}: ") for line in
                  (root / record).read_text().splitlines() if line.startswith(f"{field}: ")]
        if len(values) != 1 or not re.fullmatch(r"[0-9a-f]{64}", values[0]):
            raise CI.VerificationError(f"invalid pinned digest for {name}")
        expected[name] = values[0]
    with tempfile.TemporaryDirectory() as temporary, zipfile.ZipFile(archive) as source:
        staged = Path(temporary)
        files = source.infolist()
        # upload-artifact emits files relative to their least common ancestor.
        # Accept only the six expected files; no extraction of arbitrary paths.
        if len(files) != len(expected) or {item.filename for item in files} != set(expected):
            raise CI.VerificationError("core artifact file set is not exact")
        if sum(item.file_size for item in files) > MAX_BYTES:
            raise CI.VerificationError("expanded core artifact exceeds size limit")
        for item in files:
            mode = item.external_attr >> 16
            if item.is_dir() or stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in (0, stat.S_IFREG)):
                raise CI.VerificationError("core artifact contains a non-regular file")
            target = staged / item.filename
            target.parent.mkdir(parents=True, exist_ok=True)
            with source.open(item) as incoming, target.open("wb") as outgoing:
                shutil.copyfileobj(incoming, outgoing, 1024 * 1024)
            if file_digest(target) != expected[item.filename]:
                raise CI.VerificationError(f"pinned core SHA-256 mismatch: {item.filename}")
            destination = root / item.filename
            if any(path.is_symlink() for path in (destination, *destination.parents)):
                raise CI.VerificationError("core destination contains a symbolic link")
        # Validate the complete set before installing anything into the checkout.
        for name in expected:
            destination = root / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(staged / name, destination)


def file_digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as incoming:
        while chunk := incoming.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def restore(repo, sha, run_id=None, *, now=None, root=ROOT):
    now = now or datetime.now(timezone.utc)
    run = trusted_run(repo, sha, run_id, now)
    if run is None:
        return False
    artifacts = CI.paginated_items(
        f"repos/{repo}/actions/runs/{run['id']}/artifacts", "artifacts", (),
    )
    matches = [artifact for artifact in artifacts if artifact.get("name") == "core-assets"]
    if not matches:
        return False
    if len(matches) != 1:
        raise CI.VerificationError("CI contains duplicate core-assets artifacts")
    listed = matches[0]
    if not validate_artifact(listed, run, repo, now):
        return False
    artifact = CI.gh_api_json(f"repos/{repo}/actions/artifacts/{listed['id']}")
    if not isinstance(artifact, dict) or artifact.get("id") != listed["id"]:
        raise CI.VerificationError("artifact identity changed")
    available = validate_artifact(artifact, run, repo, now)
    if any(artifact[field] != listed[field] for field in ("digest", "size_in_bytes")):
        raise CI.VerificationError("artifact content identity changed")
    if not available:
        return False
    with tempfile.TemporaryDirectory() as temporary:
        archive = Path(temporary) / "cores.zip"
        download_archive(repo, artifact["id"], archive)
        # A rerun may have started during download; recheck the gate before use.
        if trusted_run(repo, sha, run["id"], now) is None:
            return False
        install_archive(archive, artifact, root)
    print(f"Reused verified cores from {run['html_url']} (artifact {artifact['id']})")
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--run-id", type=int)
    arguments = parser.parse_args()
    if (arguments.repo != "Elegying/SSRVPN" or
            not re.fullmatch(r"[0-9a-f]{40}", arguments.sha) or
            (arguments.run_id is not None and arguments.run_id <= 0)):
        parser.error("invalid repository, commit or run identity")
    try:
        head = subprocess.check_output(["git", "rev-parse", "HEAD^{commit}"], cwd=ROOT, text=True).strip()
        if head != arguments.sha:
            raise CI.VerificationError("checkout does not match the requested CI commit")
        return 0 if restore(arguments.repo, arguments.sha, arguments.run_id) else CI.NOT_FOUND_EXIT
    except (CI.VerificationError, OSError, ValueError, KeyError, TypeError,
            subprocess.SubprocessError, zipfile.BadZipFile) as error:
        print(f"CI core reuse failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
