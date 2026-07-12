#!/usr/bin/env python3
"""Generate deterministic tag/commit provenance for canonical release assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_provenance(tag: str, commit: str, assets: list[Path]) -> dict:
    if re.fullmatch(r"v[0-9]+(?:\.[0-9]+){1,3}", tag) is None:
        raise ValueError(f"invalid release tag: {tag}")
    if re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        raise ValueError("release commit must be a lowercase 40-character SHA")
    names = [path.name for path in assets]
    if len(names) != len(set(names)):
        raise ValueError("duplicate release asset name")
    return {
        "schema": 1,
        "tag": tag,
        "commit": commit,
        "assets": {path.name: sha256(path) for path in sorted(assets)},
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--asset", action="append", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    provenance = build_provenance(args.tag, args.commit, args.asset)
    args.output.write_text(
        json.dumps(provenance, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
