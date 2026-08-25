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


def platform_required(paths: Iterable[str]) -> bool:
    changed = list(paths)
    if not changed:
        return True
    return any(
        not (
            ("/" not in path and path.endswith(".md"))
            or (path.startswith("docs/") and len(path) > len("docs/"))
        )
        for path in changed
    )


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
    args = parser.parse_args()

    if args.event == "workflow_dispatch":
        print("true")
        return 0
    if args.event not in {"pull_request", "push"}:
        print(f"Unknown CI event {args.event!r}; running full CI", file=sys.stderr)
        print("true")
        return 0

    paths = changed_paths(args.event, args.base, args.head)
    print("true" if paths is None or platform_required(paths) else "false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
