#!/usr/bin/env python3
"""Compare generated notes against read-back GitHub and OSS metadata."""
import argparse
import json
from pathlib import Path


def verify(notes, tag, release, manifests):
    expected = notes.strip()
    if not expected or not expected.startswith(f"## SSRVPN {tag}\n"):
        raise SystemExit("Expected notes are empty or belong to another tag")
    if release.get("tag_name") != tag or release.get("body", "").strip() != expected:
        raise SystemExit("GitHub release notes differ from generated CHANGELOG notes")
    for manifest in manifests:
        if (manifest.get("version") != tag.removeprefix("v") or
                manifest.get("changelog", "").strip() != expected):
            raise SystemExit("OSS release notes differ from generated CHANGELOG notes")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--notes", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--github", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, action="append", required=True)
    args = parser.parse_args()
    verify(args.notes.read_text(encoding="utf-8"), args.tag,
           json.loads(args.github.read_text(encoding="utf-8")),
           [json.loads(path.read_text(encoding="utf-8")) for path in args.manifest])
    print("Release notes match CHANGELOG, GitHub and OSS.")


if __name__ == "__main__":
    main()
