#!/usr/bin/env python3
"""Decide whether CI must run the platform-specific jobs."""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from collections.abc import Iterable


FULL_SHA = re.compile(r"[0-9a-fA-F]{40}")

_DOC_IMAGE_SUFFIXES = (".md", ".png", ".jpg", ".jpeg", ".webp")


def _is_documentation(path: str) -> bool:
    # Root-level markdown (README.md, AGENTS.md, CHANGELOG.md, ...).
    if "/" not in path and path.endswith(".md"):
        return True
    # The docs tree.
    if path.startswith("docs/") and path.endswith(_DOC_IMAGE_SUFFIXES):
        return True
    # The in-repo project-knowledge skill: pure markdown, no product code.
    if path.startswith(".workbuddy-ai/") and path.endswith(".md"):
        return True
    return False


# Deliberately explicit: no scripts/** or workflows/** shortcut. Build helpers,
# installers, signing, core inputs and the classifier itself stay full CI.
_RELEASE_TOOLING = {
    ".github/workflows/prepare-release.yml",
    "scripts/prepare-release.sh",
    "scripts/generate-release-notes.py",
    "scripts/verify-release-notes.py",
    "scripts/generate-oss-release-manifest.py",
    "scripts/generate-release-provenance.py",
    "scripts/promote-oss-public-channel.sh",
    "scripts/prune_legacy_oss_releases.py",
    "scripts/wait-for-github-release-public.sh",
    "scripts/check-release-assets.sh",
    "scripts/authorize-existing-release-retry.py",
    "scripts/validate-existing-release-retry.py",
    "scripts/reuse-github-release-assets.sh",
    "scripts/find-reusable-main-ci.py",
    "scripts/test_generate_release_notes.py",
    "scripts/test_generate_oss_release_manifest.py",
    "scripts/test_generate_release_provenance.py",
    "scripts/test_promote_oss_public_channel.py",
    "scripts/test_prune_legacy_oss_releases.py",
    "scripts/test_prepare_release_workflow.py",
    "scripts/test_wait_for_github_release_public.py",
    "scripts/test_check_release_assets.py",
    "scripts/test_authorize_existing_release_retry.py",
    "scripts/test_validate_existing_release_retry.py",
    "scripts/test_reuse_github_release_assets.py",
    "scripts/test_find_reusable_main_ci.py",
    "scripts/test_verify_main_branch_protection.py",
    "scripts/test_verify_release_transition.py",
    "scripts/test_oss_network_boundaries.py",
}


def release_workflow_surface(source: str) -> str:
    # Ignore only publishing orchestration and the notes-only preflight step.
    # Every build/test job, trigger, permission and dependency outside publish
    # must stay byte-identical. New jobs or an unrecognized layout fail closed.
    jobs = list(re.finditer(r"^  ([a-zA-Z0-9_-]+):\n", source, re.MULTILINE))
    publish = [i for i, item in enumerate(jobs) if item[1] == "publish"]
    if len(publish) != 1:
        raise ValueError("unrecognized release publish job")
    i = publish[0]
    end = jobs[i + 1].start() if i + 1 < len(jobs) else len(source)
    publish_block = source[jobs[i].start():end]
    if publish_block.count("    steps:\n") != 1:
        raise ValueError("unrecognized release publish steps")
    # Preserve publication dependencies, environment approval and permissions.
    steps_start = jobs[i].start() + publish_block.index("    steps:\n") + len("    steps:\n")
    source = source[:steps_start] + source[end:]
    notes_step = (
        "      - name: Validate concrete release notes before building\n"
        "        if: startsWith(github.ref, 'refs/tags/')\n"
        '        run: python3 scripts/generate-release-notes.py --tag "$GITHUB_REF_NAME" --output "$RUNNER_TEMP/release-notes.md"\n\n'
    )
    # Only this exact notes command is exempt; adding a build command under the
    # same display name must not get the publishing-only shortcut.
    if source.count("      - name: Validate concrete release notes before building") > 1:
        raise ValueError("duplicate release notes preflight")
    return source.replace(notes_step, "", 1)


def release_workflow_only(event: str, base: str, head: str) -> bool:
    try:
        if event == "pull_request":
            base = subprocess.check_output(["git", "merge-base", base, head], text=True).strip()
        versions = [subprocess.check_output(
            ["git", "show", f"{revision}:.github/workflows/release.yml"],
            stderr=subprocess.PIPE).decode("utf-8") for revision in (base, head)]
        return release_workflow_surface(versions[0]) == release_workflow_surface(versions[1])
    except (subprocess.CalledProcessError, UnicodeError, ValueError):
        return False


def classify(paths: Iterable[str], *, release_workflow_safe: bool = False) -> str:
    changed = list(paths)
    if not changed:
        return "full"
    if all(_is_documentation(path) for path in changed):
        return "docs"
    if all(_is_documentation(path) or path in _RELEASE_TOOLING or
           (path == ".github/workflows/release.yml" and release_workflow_safe)
           for path in changed):
        return "release-tooling"
    return "full"


def platform_required(paths: Iterable[str]) -> bool:
    return classify(paths) == "full"


def valid_revision(value: str) -> bool:
    return bool(FULL_SHA.fullmatch(value)) and value != "0" * 40


def changed_paths(event: str, base: str, head: str) -> list[str] | None:
    if not valid_revision(base) or not valid_revision(head):
        print("CI scope revisions are missing or malformed; running full CI", file=sys.stderr)
        return None

    separator = "..." if event == "pull_request" else ".."
    result = subprocess.run(
        [
            "git",
            "diff",
            "--name-only",
            "--no-renames",
            "-z",
            f"{base}{separator}{head}",
            "--",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        message = result.stderr.decode(errors="replace").strip()
        print(f"CI scope diff failed; running full CI: {message}", file=sys.stderr)
        return None

    return [os.fsdecode(path) for path in result.stdout.split(b"\0") if path]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--event", required=True)
    parser.add_argument("--base", default="")
    parser.add_argument("--head", default="")
    parser.add_argument("--kind", action="store_true")
    args = parser.parse_args()

    def emit(kind):
        print(kind if args.kind else ("true" if kind == "full" else "false"))

    if args.event == "workflow_dispatch":
        emit("full")
        return 0
    if args.event not in {"pull_request", "push"}:
        print(f"Unknown CI event {args.event!r}; running full CI", file=sys.stderr)
        emit("full")
        return 0

    paths = changed_paths(args.event, args.base, args.head)
    kind = "full" if paths is None else classify(paths, release_workflow_safe=(
        ".github/workflows/release.yml" in paths and
        release_workflow_only(args.event, args.base, args.head)))
    emit(kind)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
