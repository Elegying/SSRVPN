#!/usr/bin/env python3
"""Reject a public release that would move the update channel backwards."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


VERSION_RE = re.compile(r"^\d+(?:\.\d+){1,3}$")


def _version_parts(version: str) -> tuple[int, ...]:
    normalized = version.removeprefix("v")
    if not VERSION_RE.fullmatch(normalized):
        raise ValueError(f"invalid release version: {version}")
    parts = tuple(int(part) for part in normalized.split("."))
    return parts + (0,) * (4 - len(parts))


def require_monotonic_release(target: str, current: str | None) -> None:
    if current is None or not current.strip():
        _version_parts(target)
        return
    if _version_parts(target) < _version_parts(current):
        raise ValueError(
            f"target version {target} is older than public version {current}"
        )


def require_newer_release(target: str, current: str) -> None:
    if _version_parts(target) <= _version_parts(current):
        raise ValueError(
            f"target version {target} must be newer than previous release {current}"
        )


def require_increasing_build_code(target: int, current: int) -> None:
    if target <= current:
        raise ValueError(
            f"Android build code {target} must be greater than previous {current}"
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--target", required=True)
    parser.add_argument("--current-manifest", type=Path)
    parser.add_argument("--current-version")
    parser.add_argument("--target-build-code", type=int)
    parser.add_argument("--current-build-code", type=int)
    args = parser.parse_args()

    current: str | None = None
    if args.current_manifest is not None and args.current_manifest.is_file():
        raw = json.loads(args.current_manifest.read_text(encoding="utf-8"))
        if not isinstance(raw, dict) or not isinstance(raw.get("version"), str):
            raise ValueError("current manifest has no valid version")
        current = raw["version"]
    require_monotonic_release(args.target, current)
    if args.current_version is not None:
        require_newer_release(args.target, args.current_version)
    if (args.target_build_code is None) != (args.current_build_code is None):
        raise ValueError("both Android build code arguments are required together")
    if args.target_build_code is not None and args.current_build_code is not None:
        require_increasing_build_code(
            args.target_build_code,
            args.current_build_code,
        )


if __name__ == "__main__":
    main()
