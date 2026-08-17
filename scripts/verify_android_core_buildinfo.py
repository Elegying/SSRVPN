#!/usr/bin/env python3
"""Verify the pinned Android Go core's embedded build contract."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path


MAGIC = b"\xff Go buildinf:"
HEADER_SIZE = 32
BUILD_INFO_START = bytes.fromhex("3077af0c9274080241e1c107e6d618e6")
BUILD_INFO_END = bytes.fromhex("f932433186182072008242104116d8f2")


class BuildInfoError(ValueError):
    pass


@dataclass(frozen=True)
class AndroidCoreBuildInfo:
    go_version: str
    dependencies: dict[str, str]
    local_replacements: frozenset[str]
    settings: dict[str, str]


def _read_uvarint(data: bytes, offset: int) -> tuple[int, int]:
    value = 0
    shift = 0
    for _ in range(10):
        if offset >= len(data):
            raise BuildInfoError("truncated inline Go build info")
        current = data[offset]
        offset += 1
        if current < 0x80:
            return value | (current << shift), offset
        value |= (current & 0x7F) << shift
        shift += 7
    raise BuildInfoError("invalid inline Go build info length")


def _read_inline_string(data: bytes, offset: int) -> tuple[bytes, int]:
    size, offset = _read_uvarint(data, offset)
    end = offset + size
    if end > len(data):
        raise BuildInfoError("truncated Go module framing")
    return data[offset:end], end


def parse_build_info(data: bytes) -> AndroidCoreBuildInfo:
    start = data.find(MAGIC)
    if start < 0 or start + HEADER_SIZE > len(data):
        raise BuildInfoError("Go build info header is missing")
    flags = data[start + len(MAGIC) + 1]
    if flags & 2 == 0:
        raise BuildInfoError("only inline Go build info is supported")

    offset = start + HEADER_SIZE
    raw_version, offset = _read_inline_string(data, offset)
    raw_module, _ = _read_inline_string(data, offset)
    if (
        len(raw_module) < len(BUILD_INFO_START) + len(BUILD_INFO_END)
        or not raw_module.startswith(BUILD_INFO_START)
        or not raw_module.endswith(BUILD_INFO_END)
    ):
        raise BuildInfoError("invalid Go module framing")

    try:
        go_version = raw_version.decode("utf-8")
        lines = raw_module[len(BUILD_INFO_START) : -len(BUILD_INFO_END)].decode(
            "utf-8"
        ).splitlines()
    except UnicodeDecodeError as error:
        raise BuildInfoError("Go build info is not valid UTF-8") from error

    dependencies: dict[str, str] = {}
    replacements: set[str] = set()
    settings: dict[str, str] = {}
    previous_dependency: str | None = None
    for line in lines:
        fields = line.split("\t")
        if len(fields) >= 3 and fields[0] == "dep":
            previous_dependency = fields[1]
            dependencies[fields[1]] = fields[2]
        elif len(fields) >= 2 and fields[0] == "=>" and previous_dependency:
            replacements.add(previous_dependency)
        elif len(fields) >= 2 and fields[0] == "build":
            setting = fields[1]
            key, separator, value = setting.partition("=")
            settings[key] = value if separator else "true"

    return AndroidCoreBuildInfo(
        go_version=go_version,
        dependencies=dependencies,
        local_replacements=frozenset(replacements),
        settings=settings,
    )


def _source_fields(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        key, separator, value = line.partition(": ")
        if separator:
            fields[key] = value
    return fields


def verify(binary: Path, source_record: Path) -> AndroidCoreBuildInfo:
    fields = _source_fields(source_record)
    required = (
        "Go version",
        "Go module",
        "Go module version",
        "Build mode",
        "Build tags",
        "Target",
    )
    missing = [field for field in required if not fields.get(field)]
    if missing:
        raise BuildInfoError(
            f"source record is missing build fields: {', '.join(missing)}"
        )

    info = parse_build_info(binary.read_bytes())
    module = fields["Go module"]
    expected_target = fields["Target"].split("/", maxsplit=1)
    if len(expected_target) != 2:
        raise BuildInfoError("source record Target must use GOOS/GOARCH")
    checks = {
        "Go version": (info.go_version, fields["Go version"]),
        "Go module version": (
            info.dependencies.get(module, "missing"),
            fields["Go module version"],
        ),
        "Build mode": (info.settings.get("-buildmode", "missing"), fields["Build mode"]),
        "Build tags": (info.settings.get("-tags", "missing"), fields["Build tags"]),
        "GOOS": (info.settings.get("GOOS", "missing"), expected_target[0]),
        "GOARCH": (info.settings.get("GOARCH", "missing"), expected_target[1]),
    }
    mismatches = [
        f"{label}: expected {expected}, got {actual}"
        for label, (actual, expected) in checks.items()
        if actual != expected
    ]
    if module not in info.local_replacements:
        mismatches.append(f"{module} is not recorded as a local source replacement")
    if mismatches:
        raise BuildInfoError("; ".join(mismatches))
    return info


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("binary", type=Path)
    parser.add_argument("source_record", type=Path)
    args = parser.parse_args()
    try:
        info = verify(args.binary, args.source_record)
    except (BuildInfoError, OSError) as error:
        raise SystemExit(f"Android core build info check failed: {error}") from error
    print(
        "ok Android core build info: "
        f"{info.go_version} android/arm64 c-shared with_gvisor"
    )


if __name__ == "__main__":
    main()
