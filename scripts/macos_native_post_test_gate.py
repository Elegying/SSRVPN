#!/usr/bin/env python3
"""Detect macOS XCTest host crashes and residual test processes."""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import time
from typing import Iterable, List, Optional, Sequence, Set, Tuple


ReportSnapshot = Set[str]
ProcessIdentity = Tuple[int, str]

_REPORT_PATTERNS = (
    "SSRVPN-*.ips",
    "SSRVPN_*.ips",
    "SSRVPN-*.crash",
    "SSRVPN_*.crash",
)
_MAX_REPORT_BYTES = 64 * 1024 * 1024
_DEBUG_HOST_SUFFIX = (
    "/Build/Products/Debug/SSRVPN.app/Contents/MacOS/SSRVPN"
)
_APP_EXECUTABLE_SUFFIX = "/SSRVPN.app/Contents/MacOS/SSRVPN"
_SSRVPN_TEMPORARY_PATH_PREFIXES = (
    "/private/tmp/",
    "/tmp/",
    "/private/var/folders/",
    "/var/folders/",
)
_ATLAS_TEMPORARY_PATH_PREFIXES = _SSRVPN_TEMPORARY_PATH_PREFIXES
_PROCESS_LINE = re.compile(
    r"^\s*(?P<pid>\d+)\s+(?P<ppid>\d+)\s+(?P<uid>\d+)\s+(?P<command>.+)$"
)
_SSRVPN_COMMAND = re.compile(
    r"^(?P<path>/.+?/SSRVPN\.app/Contents/MacOS/SSRVPN)(?:\s|$)"
)
_ATLAS_COMMAND = re.compile(r"^(?P<path>/.+?/AtlasCore)(?:\s|$)")
_REPORT_PATH = re.compile(
    r'(/[^"\n]*?/SSRVPN\.app/Contents/MacOS/SSRVPN)'
)


def _is_regular_file(path: Path) -> bool:
    try:
        details = os.lstat(str(path))
    except OSError:
        return False
    return stat.S_ISREG(details.st_mode)


def snapshot_reports(reports_directory: Path) -> ReportSnapshot:
    snapshot: ReportSnapshot = set()
    if not reports_directory.is_dir():
        return snapshot
    paths = {
        path
        for pattern in _REPORT_PATTERNS
        for path in reports_directory.glob(pattern)
    }
    for path in sorted(paths):
        if _is_regular_file(path):
            snapshot.add(str(path.resolve()))
    return snapshot


def write_snapshot(snapshot: ReportSnapshot, output: Path) -> None:
    output.write_text(
        json.dumps(sorted(snapshot), ensure_ascii=False),
        encoding="utf-8",
    )


def read_snapshot(path: Path) -> ReportSnapshot:
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, list) or not all(isinstance(path, str) for path in raw):
        raise ValueError("Crash report baseline must be a JSON string array")
    return set(raw)


def changed_report_paths(
    baseline: ReportSnapshot,
    current: ReportSnapshot,
) -> List[Path]:
    return [Path(path) for path in sorted(current - baseline)]


def _collect_json_paths(value: object) -> Iterable[str]:
    if isinstance(value, dict):
        for key, child in value.items():
            if key in ("procPath", "path") and isinstance(child, str):
                yield child
            yield from _collect_json_paths(child)
    elif isinstance(value, list):
        for child in value:
            yield from _collect_json_paths(child)


def _decoded_report_objects(contents: str) -> Iterable[object]:
    lines = contents.splitlines()
    candidates = [contents]
    if len(lines) > 1:
        candidates.append("\n".join(lines[1:]))
    if lines:
        candidates.append(lines[0])
    seen = set()
    for candidate in candidates:
        if not candidate.strip() or candidate in seen:
            continue
        seen.add(candidate)
        try:
            yield json.loads(candidate)
        except json.JSONDecodeError:
            continue


def report_paths(path: Path) -> List[str]:
    try:
        flags = (
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        descriptor = os.open(str(path), flags)
    except OSError:
        return []
    try:
        details = os.fstat(descriptor)
        if not stat.S_ISREG(details.st_mode) or details.st_size > _MAX_REPORT_BYTES:
            return []
        with os.fdopen(descriptor, "rb", closefd=False) as handle:
            contents_bytes = handle.read(_MAX_REPORT_BYTES + 1)
    finally:
        os.close(descriptor)
    if len(contents_bytes) > _MAX_REPORT_BYTES:
        return []
    contents = contents_bytes.decode("utf-8", errors="replace")
    discovered = {
        report_path
        for decoded in _decoded_report_objects(contents)
        for report_path in _collect_json_paths(decoded)
    }
    discovered.update(match.group(1) for match in _REPORT_PATH.finditer(contents))
    return sorted(discovered)


def is_test_host_path(path: str) -> bool:
    normalized = path.replace("\\/", "/")
    if (
        normalized.startswith("/Applications/SSRVPN.app/")
        or "/AppTranslocation/" in normalized
    ):
        return False
    if normalized.endswith(_DEBUG_HOST_SUFFIX):
        return True
    return normalized.endswith(_APP_EXECUTABLE_SUFFIX) and normalized.startswith(
        _SSRVPN_TEMPORARY_PATH_PREFIXES
    )


def report_is_test_host(path: Path) -> Optional[bool]:
    executable_paths = [
        candidate.replace("\\/", "/")
        for candidate in report_paths(path)
        if candidate.replace("\\/", "/").endswith(_APP_EXECUTABLE_SUFFIX)
    ]
    if not executable_paths:
        return None
    return any(is_test_host_path(candidate) for candidate in executable_paths)


def _is_temporary_atlas_path(path: str) -> bool:
    return (
        "/Library/Developer/Xcode/DerivedData/" in path
        or path.startswith(_ATLAS_TEMPORARY_PATH_PREFIXES)
    )


def _matched_executable_path(pattern: re.Pattern, command: str) -> Optional[str]:
    match = pattern.match(command)
    if match is None:
        return None
    path = match.group("path")
    # The command column starts with the executable. A later absolute-path
    # argument must not be mistaken for the executable itself.
    if " /" in path:
        return None
    return path


def process_identities(process_list: str, expected_uid: int) -> Set[ProcessIdentity]:
    identities: Set[ProcessIdentity] = set()
    for line in process_list.splitlines():
        match = _PROCESS_LINE.match(line)
        if match is not None and int(match.group("uid")) == expected_uid:
            identities.add((int(match.group("pid")), match.group("command")))
    return identities


def residual_test_processes(
    process_list: str,
    expected_uid: int,
    derived_data_path: Path,
    baseline_process_list: str = "",
) -> List[str]:
    residual: List[str] = []
    baseline = process_identities(baseline_process_list, expected_uid)
    expected_host_path = os.path.realpath(
        str(
            derived_data_path
            / "Build/Products/Debug/SSRVPN.app/Contents/MacOS/SSRVPN"
        )
    )
    for line in process_list.splitlines():
        match = _PROCESS_LINE.match(line)
        if match is None or int(match.group("uid")) != expected_uid:
            continue
        command = match.group("command")
        identity = (int(match.group("pid")), command)
        if identity in baseline:
            continue
        ssrvpn_path = _matched_executable_path(_SSRVPN_COMMAND, command)
        atlas_path = _matched_executable_path(_ATLAS_COMMAND, command)
        if (
            ssrvpn_path is not None
            and (
                os.path.realpath(ssrvpn_path) == expected_host_path
                or (
                    ssrvpn_path.startswith(_SSRVPN_TEMPORARY_PATH_PREFIXES)
                    and is_test_host_path(ssrvpn_path)
                )
            )
        ):
            residual.append(line.strip())
        elif atlas_path is not None and _is_temporary_atlas_path(atlas_path):
            residual.append(line.strip())
    return residual


def read_process_list(process_list_file: Optional[Path]) -> str:
    if process_list_file is not None:
        return process_list_file.read_text(encoding="utf-8")
    result = subprocess.run(
        ["/bin/ps", "-axww", "-o", "pid=,ppid=,uid=,command="],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        raise RuntimeError(f"Could not inspect macOS processes: {result.stderr.strip()}")
    return result.stdout


def process_baseline(process_list: str, expected_uid: int) -> str:
    """Retain only process identities that the residual-process gate needs."""
    relevant: List[str] = []
    for line in process_list.splitlines():
        match = _PROCESS_LINE.match(line)
        if match is None or int(match.group("uid")) != expected_uid:
            continue
        command = match.group("command")
        ssrvpn_path = _matched_executable_path(_SSRVPN_COMMAND, command)
        atlas_path = _matched_executable_path(_ATLAS_COMMAND, command)
        if (
            ssrvpn_path is not None
            and is_test_host_path(ssrvpn_path)
        ) or (
            atlas_path is not None
            and _is_temporary_atlas_path(atlas_path)
        ):
            relevant.append(line.strip())
    return "\n".join(relevant) + ("\n" if relevant else "")


def check_post_test_state(
    reports_directory: Path,
    baseline: ReportSnapshot,
    wait_seconds: float,
    derived_data_path: Path,
    baseline_process_list: str,
    process_list_file: Optional[Path] = None,
) -> int:
    if not 0.0 <= wait_seconds <= 60.0:
        raise ValueError("Post-test wait must be between 0 and 60 seconds")
    deadline = time.monotonic() + wait_seconds
    while True:
        changed = changed_report_paths(baseline, snapshot_reports(reports_directory))
        classifications = {path: report_is_test_host(path) for path in changed}
        if any(value is True for value in classifications.values()) or time.monotonic() >= deadline:
            break
        time.sleep(min(0.25, max(0.0, deadline - time.monotonic())))

    changed = changed_report_paths(baseline, snapshot_reports(reports_directory))
    classifications = {path: report_is_test_host(path) for path in changed}
    crashed = [path for path, value in classifications.items() if value is True]
    undecodable = [path for path, value in classifications.items() if value is None]
    process_list = read_process_list(process_list_file)
    residual = residual_test_processes(
        process_list,
        os.getuid(),
        derived_data_path,
        baseline_process_list,
    )

    if undecodable:
        print("New SSRVPN crash reports could not be classified:", file=sys.stderr)
        for path in undecodable:
            print(f"  {path}", file=sys.stderr)
    if crashed:
        print("macOS XCTest host produced new crash reports:", file=sys.stderr)
        for path in crashed:
            print(f"  {path}", file=sys.stderr)
    if residual:
        print("macOS native tests left test processes running:", file=sys.stderr)
        for process in residual:
            print(f"  {process}", file=sys.stderr)
    return 1 if crashed or undecodable or residual else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    snapshot = subparsers.add_parser("snapshot")
    snapshot.add_argument("--reports-dir", required=True, type=Path)
    snapshot.add_argument("--output", required=True, type=Path)
    snapshot.add_argument("--process-output", required=True, type=Path)
    snapshot.add_argument("--process-list-file", type=Path)

    check = subparsers.add_parser("check")
    check.add_argument("--reports-dir", required=True, type=Path)
    check.add_argument("--baseline", required=True, type=Path)
    check.add_argument("--wait-seconds", required=True, type=float)
    check.add_argument("--derived-data-path", required=True, type=Path)
    check.add_argument("--process-baseline", required=True, type=Path)
    check.add_argument("--process-list-file", type=Path)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = build_parser().parse_args(argv)
    try:
        if arguments.command == "snapshot":
            write_snapshot(snapshot_reports(arguments.reports_dir), arguments.output)
            arguments.process_output.write_text(
                process_baseline(
                    read_process_list(arguments.process_list_file),
                    os.getuid(),
                ),
                encoding="utf-8",
            )
            return 0
        return check_post_test_state(
            arguments.reports_dir,
            read_snapshot(arguments.baseline),
            arguments.wait_seconds,
            arguments.derived_data_path,
            arguments.process_baseline.read_text(encoding="utf-8"),
            arguments.process_list_file,
        )
    except (OSError, RuntimeError, ValueError, json.JSONDecodeError) as error:
        print(f"macOS native post-test gate failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
