#!/usr/bin/env python3
"""Validate links and reject known-stale claims in current SSRVPN docs."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


FENCE_START = re.compile(r"^[ \t]{0,3}(`{3,}|~{3,})")
REFERENCE_DEFINITION = re.compile(
    r"^[ \t]{0,3}\[([^\]]+)\]:[ \t]*(?:<([^>]+)>|(\S+))",
    re.MULTILINE,
)
INLINE_LINK_START = re.compile(r"!?\[[^\]\n]*\]\(")
SENTENCE_BREAK = re.compile(r"(?<=[。！？!?])|(?<=\.)(?=\s|$)|\n[ \t]*\n+")
TUN_UNAVAILABLE = re.compile(
    r"不可用|不支持|暂停|停用|unavailable|unsupported|not[ \t]+supported|disabled",
    re.IGNORECASE,
)
CONDITIONAL = re.compile(r"如果|假如|若(?:是|果)?|\bif\b|\bwhen\b", re.IGNORECASE)
RECOVERY = re.compile(
    r"(?:当前|现在|现已|已经|如今).{0,12}(?:可用|恢复|支持)|"
    r"(?:restored|now[ \t]+available|currently[ \t]+available)",
    re.IGNORECASE,
)
HISTORICAL = re.compile(
    r"历史|旧版|过去|此前|曾经|当时|v\d+(?:\.\d+)+|"
    r"previously|historically|older[ \t]+versions?",
    re.IGNORECASE,
)
CURRENT_2X = re.compile(
    r"(?:当前|最新)(?:版本|发布|客户端|支持)?[^。！？.!?]{0,24}"
    r"(?<![0-9A-Za-z])v?2(?:\.x|\.\d+(?:\.\d+)?)(?![\d.])|"
    r"(?:支持|兼容)[^。！？.!?]{0,16}"
    r"(?<![0-9A-Za-z])v?2(?:\.x|\.\d+(?:\.\d+)?)(?![\d.])|"
    r"\b(?:current|latest|supported)[^。！？.!?]{0,24}"
    r"\bv?2(?:\.x|\.\d+(?:\.\d+)?)\b",
    re.IGNORECASE,
)
LEGACY_WINDOWS_UPDATE_HANDOFF = re.compile(
    r"安装器[^\u3002！？.!?]{0,16}(?:确认)?接管|"
    r"(?:更新|安装包)[^\u3002！？.!?]{0,24}交接|"
    r"(?:Windows|客户端|应用内)[^\u3002！？.!?]{0,48}更新"
    r"[^\u3002！？.!?]{0,64}安全[^\u3002！？.!?]{0,16}退出|"
    r"(?:handoff|launch(?:es|ed|ing)?)[^.!?]{0,24}(?:Windows[ \t]+)?installer",
    re.IGNORECASE,
)
LEGACY_WINDOWS_UPDATE_LINK_OPEN = re.compile(
    r"(?:Windows|应用内|客户端)[^\u3002！？.!?]{0,48}更新"
    r"[^\u3002！？.!?]{0,32}(?:打开|跳转)[^\u3002！？.!?]{0,16}(?:下载)?链接",
    re.IGNORECASE,
)
NEGATED_LINK_OPEN = re.compile(
    r"(?:不|不会|不得|禁止)[^\u3002！？.!?]{0,8}(?:打开|跳转)",
    re.IGNORECASE,
)
LIGHTWEIGHT_VERSION_TAG = re.compile(
    r"^[ \t]*(?:[$>]\s*)?git[ \t]+tag[ \t]+"
    r"(?!(?:-[as]|--(?:annotate|sign))(?:[ \t]|$))"
    r"(?P<target>v(?:X\.Y\.Z|\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?))\b",
    re.IGNORECASE | re.MULTILINE,
)


def _blank_preserving_newlines(value: str) -> str:
    return "".join("\n" if char == "\n" else " " for char in value)


def strip_code(markdown: str) -> str:
    """Remove fenced and inline code without changing line structure."""
    output: list[str] = []
    fence_char = ""
    fence_length = 0

    for line in markdown.splitlines(keepends=True):
        match = FENCE_START.match(line)
        if fence_char:
            output.append(_blank_preserving_newlines(line))
            if match and match.group(1)[0] == fence_char and len(match.group(1)) >= fence_length:
                fence_char = ""
                fence_length = 0
            continue
        if match:
            fence_char = match.group(1)[0]
            fence_length = len(match.group(1))
            output.append(_blank_preserving_newlines(line))
            continue
        output.append(line)

    text = "".join(output)
    cleaned: list[str] = []
    cursor = 0
    while cursor < len(text):
        if text[cursor] != "`":
            cleaned.append(text[cursor])
            cursor += 1
            continue
        end_of_run = cursor
        while end_of_run < len(text) and text[end_of_run] == "`":
            end_of_run += 1
        marker = text[cursor:end_of_run]
        closing = text.find(marker, end_of_run)
        if closing == -1:
            cleaned.append(marker)
            cursor = end_of_run
            continue
        closing += len(marker)
        cleaned.append(_blank_preserving_newlines(text[cursor:closing]))
        cursor = closing
    return "".join(cleaned)


def _destination(link_body: str) -> str:
    body = link_body.lstrip()
    if not body:
        return ""
    if body.startswith("<"):
        escaped = False
        for index, char in enumerate(body[1:], start=1):
            if char == ">" and not escaped:
                return body[1:index]
            escaped = char == "\\" and not escaped
        return ""

    escaped = False
    chars: list[str] = []
    for char in body:
        if char.isspace() and not escaped:
            break
        if escaped:
            chars.append(char)
            escaped = False
        elif char == "\\":
            escaped = True
        else:
            chars.append(char)
    if escaped:
        chars.append("\\")
    return "".join(chars)


def extract_link_targets(markdown: str) -> list[str]:
    """Extract inline and reference-definition link targets from Markdown."""
    text = strip_code(markdown)
    targets: list[str] = []

    for match in INLINE_LINK_START.finditer(text):
        start = match.end()
        cursor = start
        depth = 1
        escaped = False
        while cursor < len(text):
            char = text[cursor]
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
                if depth == 0:
                    target = _destination(text[start:cursor])
                    if target:
                        targets.append(target)
                    break
            cursor += 1

    for match in REFERENCE_DEFINITION.finditer(text):
        identifier = match.group(1).strip()
        if identifier.startswith("^"):
            continue
        target = match.group(2) or match.group(3) or ""
        if target:
            targets.append(target)
    return targets


def stale_claims(markdown: str) -> list[str]:
    """Return current-state claims known to contradict the present project."""
    text = strip_code(markdown)
    findings: list[str] = []
    for raw_sentence in SENTENCE_BREAK.split(text):
        sentence = re.sub(r"\s+", " ", raw_sentence).strip()
        if not sentence:
            continue

        lower = sentence.lower()
        unavailable = TUN_UNAVAILABLE.search(sentence)
        if "macos" in lower and "tun" in lower and unavailable:
            conditional = CONDITIONAL.search(sentence)
            is_conditional = conditional is not None and conditional.start() < unavailable.start()
            is_restored_history = HISTORICAL.search(sentence) and RECOVERY.search(sentence)
            if not is_conditional and not is_restored_history:
                findings.append(f"stale macOS TUN claim: {sentence}")

        if CURRENT_2X.search(sentence):
            findings.append(f"stale current-version claim: {sentence}")

        stale_link_open = LEGACY_WINDOWS_UPDATE_LINK_OPEN.search(sentence)
        if LEGACY_WINDOWS_UPDATE_HANDOFF.search(sentence) or (
            stale_link_open and not NEGATED_LINK_OPEN.search(sentence)
        ):
            findings.append(f"stale Windows update handoff claim: {sentence}")
    return findings


def stale_release_instructions(markdown: str) -> list[str]:
    """Return release commands that would create an unannotated version tag."""
    return [
        f"lightweight release tag command: {match.group(0).strip()}"
        for match in LIGHTWEIGHT_VERSION_TAG.finditer(markdown)
    ]


def _is_external(target: str) -> bool:
    if target.startswith(("#", "//")):
        return True
    parsed = urlsplit(target)
    return bool(parsed.scheme or parsed.netloc)


def validate(root: Path, docs: list[str]) -> list[str]:
    errors: list[str] = []
    root = root.resolve()
    for relative_name in docs:
        document = (root / relative_name).resolve()
        try:
            document.relative_to(root)
        except ValueError:
            errors.append(f"document escapes repository root: {relative_name}")
            continue
        if not document.is_file():
            errors.append(f"missing current document: {relative_name}")
            continue

        markdown = document.read_text(encoding="utf-8")
        for target in extract_link_targets(markdown):
            if _is_external(target):
                continue
            path_text = unquote(urlsplit(target).path)
            if not path_text:
                continue
            candidate = (root / path_text.lstrip("/")) if path_text.startswith("/") else (document.parent / path_text)
            candidate = candidate.resolve()
            try:
                candidate.relative_to(root)
            except ValueError:
                errors.append(f"{relative_name}: link escapes repository root: {target}")
                continue
            if not candidate.exists():
                errors.append(f"{relative_name}: broken local link: {target}")

        for finding in stale_claims(markdown):
            errors.append(f"{relative_name}: {finding}")
        for finding in stale_release_instructions(markdown):
            errors.append(f"{relative_name}: {finding}")
    return sorted(set(errors))


def self_test() -> None:
    link_sample = """
[nested](docs/guide_(advanced).md)
[with title](docs/guide.md "Guide")
```markdown
[fenced](missing.md)
```
`[inline](also-missing.md)`
[^source]: missing-footnote.md
[guide]: <docs/reference guide.md>
"""
    assert extract_link_targets(link_sample) == [
        "docs/guide_(advanced).md",
        "docs/guide.md",
        "docs/reference guide.md",
    ]
    assert stale_claims("macOS TUN 当前\n不可用。")
    assert stale_claims("TUN 在 macOS 上不支持。")
    assert not stale_claims("如果 macOS TUN 不可用，请先检查管理员授权。")
    assert not stale_claims("macOS TUN 在 v2.4.5 中不可用，但当前已恢复。")
    assert stale_claims("当前版本仍为v2.4.5。")
    assert not stale_claims("迁移来源是不可变的 v2.4.5 APK。")
    assert not stale_claims("`macOS TUN 当前不可用。`")
    assert stale_claims(
        "检查 Windows 应用内更新；安装器确认接管后应用必须安全恢复代理并退出。"
    )
    assert not stale_claims(
        "Windows 更新包校验后保存到真实桌面，客户端提示用户手动安装并保持运行。"
    )
    assert stale_claims("Windows 应用内更新会打开正确下载链接。")
    assert stale_release_instructions("```bash\ngit tag v3.4.8\n```")
    assert stale_release_instructions("git tag vX.Y.Z")
    assert not stale_release_instructions(
        '```bash\ngit tag -a v3.4.8 -m "SSRVPN v3.4.8"\n```'
    )
    assert not stale_release_instructions("git tag --annotate v3.4.8")
    assert not stale_release_instructions("git tag -l 'v*'")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", nargs="?")
    parser.add_argument("docs", nargs="*")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        print("Documentation consistency self-tests passed.")
        return 0
    if not args.root or not args.docs:
        parser.error("root and at least one current document are required")

    errors = validate(Path(args.root), args.docs)
    if errors:
        print("Documentation consistency check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"Documentation consistency checks passed ({len(args.docs)} current documents).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
