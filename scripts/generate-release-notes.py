#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path


DOWNLOADS = """### 下载
| 平台 | 文件 | 校验和 |
|----------|------|----------|
| Android | `SSRVPN.apk` | `SSRVPN.apk.sha256` |
| macOS | `SSRVPN.dmg` | `SSRVPN.dmg.sha256` |
| Windows 安装版 | `SSRVPN_Setup.exe` | `SSRVPN_Setup.exe.sha256` |

校验 SHA256：`shasum -a 256 -c <file>.sha256`
"""

CHANGELOG_HEADINGS = {
    "Added": "新增",
    "Changed": "变更",
    "Deprecated": "废弃",
    "Removed": "移除",
    "Fixed": "修复",
    "Security": "安全",
}


def normalize_changelog_headings(notes: str) -> str:
    for english, chinese in CHANGELOG_HEADINGS.items():
        notes = re.sub(
            rf"^###\s+{re.escape(english)}\s*$",
            f"### {chinese}",
            notes,
            flags=re.MULTILINE,
        )
    return notes


def extract_changelog_section(changelog: str, tag: str) -> str:
    version = tag[1:] if tag.startswith("v") else tag
    heading = re.compile(
        rf"^## \[{re.escape(version)}\](?:\s+-\s+\d{{4}}-\d{{2}}-\d{{2}})?\s*$",
        re.MULTILINE,
    )
    match = heading.search(changelog)
    if match is None:
        raise SystemExit(f"CHANGELOG.md does not contain a [{version}] section")

    start = match.end()
    if start < len(changelog) and changelog[start] == "\n":
        start += 1

    next_heading = re.search(r"^## \[", changelog[start:], re.MULTILINE)
    end = start + next_heading.start() if next_heading else len(changelog)
    section = changelog[start:end].strip()
    return normalize_changelog_headings(section) or f"- 发布 {tag}"


def build_release_notes(changelog_path: Path, tag: str) -> str:
    changelog = changelog_path.read_text(encoding="utf-8")
    notes = extract_changelog_section(changelog, tag)
    return f"## SSRVPN {tag}\n\n{notes}\n\n{DOWNLOADS}"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Generate GitHub release notes from CHANGELOG.md.",
    )
    parser.add_argument("--tag", required=True, help="Release tag, for example v2.0.13")
    parser.add_argument(
        "--changelog",
        default="CHANGELOG.md",
        help="Path to the changelog file",
    )
    parser.add_argument(
        "--output",
        required=True,
        help="Path where the release notes markdown will be written",
    )
    args = parser.parse_args()

    body = build_release_notes(Path(args.changelog), args.tag)
    Path(args.output).write_text(body, encoding="utf-8")
    print(f"release notes: wrote {args.output} from {args.changelog} [{args.tag}]")


if __name__ == "__main__":
    main()
