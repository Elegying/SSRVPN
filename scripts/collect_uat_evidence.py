#!/usr/bin/env python3
"""Collect auditable macOS/Android UAT snapshots without changing settings."""

from __future__ import annotations

import argparse
import json
import math
import platform
import re
import subprocess
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Sequence


ANDROID_PACKAGE = "com.ssrvpn.android"
Runner = Callable[[list[str]], str]


def run_command(command: list[str]) -> str:
    completed = subprocess.run(
        command,
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    return completed.stdout


def run_optional(command: list[str], runner: Runner) -> str:
    try:
        return runner(command).strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def first_match(pattern: str, value: str, default: str = "") -> str:
    match = re.search(pattern, value, re.MULTILINE)
    return match.group(1).strip() if match else default


def parse_bool_field(value: str, name: str) -> bool:
    return (
        first_match(rf"^\s*{re.escape(name)}:\s*(true|false)\s*$", value)
        == "true"
    )


def parse_int(value: str, default: int = 0) -> int:
    try:
        return int(value.strip())
    except (TypeError, ValueError):
        return default


def collect_android_snapshot(
    serial: str,
    runner: Runner = run_command,
    captured_at: str | None = None,
) -> dict[str, Any]:
    if not serial.strip():
        raise ValueError("an explicit Android device serial is required")

    def shell(*args: str) -> str:
        return runner(["adb", "-s", serial, "shell", *args]).strip()

    package_dump = shell("dumpsys", "package", ANDROID_PACKAGE)
    battery_dump = shell("dumpsys", "battery")
    pid_text = shell("pidof", ANDROID_PACKAGE)
    meminfo = shell("dumpsys", "meminfo", ANDROID_PACKAGE)
    ac_powered = parse_bool_field(battery_dump, "AC powered")
    usb_powered = parse_bool_field(battery_dump, "USB powered")
    wireless_powered = parse_bool_field(battery_dump, "Wireless powered")

    return {
        "schema_version": 1,
        "platform": "android",
        "captured_at": captured_at or datetime.now().astimezone().isoformat(),
        "device": {
            "serial": serial,
            "model": shell("getprop", "ro.product.model"),
            "android_version": shell("getprop", "ro.build.version.release"),
            "sdk": parse_int(shell("getprop", "ro.build.version.sdk")),
            "abi": shell("getprop", "ro.product.cpu.abi"),
            "page_size_bytes": parse_int(shell("getconf", "PAGESIZE")),
        },
        "app": {
            "package": ANDROID_PACKAGE,
            "version_name": first_match(r"^\s*versionName=([^\s]+)", package_dump),
            "version_code": parse_int(
                first_match(r"^\s*versionCode=(\d+)", package_dump)
            ),
        },
        "battery": {
            "ac_powered": ac_powered,
            "usb_powered": usb_powered,
            "wireless_powered": wireless_powered,
            "powered": ac_powered or usb_powered or wireless_powered,
            "status": parse_int(first_match(r"^\s*status:\s*(\d+)", battery_dump)),
            "level_percent": parse_int(
                first_match(r"^\s*level:\s*(\d+)", battery_dump)
            ),
            "temperature_c": parse_int(
                first_match(r"^\s*temperature:\s*(\d+)", battery_dump)
            )
            / 10.0,
        },
        "process": {
            "pid": parse_int(pid_text) or None,
            "total_pss_kib": parse_int(
                first_match(r"TOTAL PSS:\s*(\d+)", meminfo)
            ),
            "total_rss_kib": parse_int(
                first_match(r"TOTAL RSS:\s*(\d+)", meminfo)
            ),
        },
    }


def android_acceptance_verdict(snapshot: dict[str, Any]) -> dict[str, Any]:
    page_size = int(snapshot.get("device", {}).get("page_size_bytes", 0))
    battery = snapshot.get("battery", {})
    powered = bool(battery.get("powered", False))
    battery_status = int(battery.get("status", 0))
    charging = battery_status in (2, 5)
    is_16k = page_size == 16384
    return {
        "android_16k_hardware": is_16k,
        "android_16k_reason": (
            "runtime page size is 16384 bytes"
            if is_16k
            else f"runtime page size is {page_size} bytes, not 16384"
        ),
        "battery_baseline_ready": not powered and not charging,
        "battery_reason": (
            "device is using external power; discharge evidence would be invalid"
            if powered
            else (
                "battery status is charging or full; disconnect power before sampling"
                if charging
                else "device is not using external power and is discharging"
            )
        ),
    }


def macos_process_queries(
    app_path: Path, executable_name: str
) -> tuple[list[str], Callable[[int], list[str]]]:
    executable_path = app_path / "Contents" / "MacOS" / executable_name
    exact_process = rf"^{re.escape(str(executable_path))}($| )"

    def process_status(pid: int) -> list[str]:
        return ["ps", "-o", "pid=,rss=,etime=", "-p", str(pid)]

    return ["pgrep", "-f", exact_process], process_status


def collect_macos_snapshot(
    app_path: Path,
    runner: Runner = run_command,
    captured_at: str | None = None,
) -> dict[str, Any]:
    info_plist = app_path / "Contents" / "Info.plist"
    app_version = ""
    build_number = ""
    executable_name = app_path.stem
    if info_plist.is_file():
        app_version = run_optional(
            [
                "plutil",
                "-extract",
                "CFBundleShortVersionString",
                "raw",
                "-o",
                "-",
                str(info_plist),
            ],
            runner,
        )
        build_number = run_optional(
            [
                "plutil",
                "-extract",
                "CFBundleVersion",
                "raw",
                "-o",
                "-",
                str(info_plist),
            ],
            runner,
        )
        executable_name = run_optional(
            [
                "plutil",
                "-extract",
                "CFBundleExecutable",
                "raw",
                "-o",
                "-",
                str(info_plist),
            ],
            runner,
        ) or executable_name

    process_match, process_status = macos_process_queries(app_path, executable_name)
    pids = run_optional(process_match, runner).split()
    process_rows = []
    for pid in pids:
        if pid.isdigit():
            row = run_optional(process_status(int(pid)), runner)
            if row:
                process_rows.append(row)

    listeners = {}
    for port in (7890, 7891, 9090):
        listeners[str(port)] = run_optional(
            ["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN"], runner
        )

    return {
        "schema_version": 1,
        "platform": "macos",
        "captured_at": captured_at or datetime.now().astimezone().isoformat(),
        "host": {
            "macos_version": runner(["sw_vers", "-productVersion"]).strip(),
            "architecture": platform.machine(),
            "page_size_bytes": parse_int(runner(["sysctl", "-n", "hw.pagesize"])),
        },
        "app": {
            "path": str(app_path),
            "exists": app_path.is_dir(),
            "version_name": app_version,
            "build_number": build_number,
            "executable": executable_name,
        },
        "runtime": {
            "processes": process_rows,
            "proxy": runner(["scutil", "--proxy"]).strip(),
            "listeners": listeners,
            "power": run_optional(["pmset", "-g", "batt"], runner),
        },
    }


def summarize_timings(samples: Sequence[float]) -> dict[str, float | int]:
    if not samples:
        raise ValueError("at least one timing sample is required")
    ordered = sorted(float(sample) for sample in samples)
    count = len(ordered)
    midpoint = count // 2
    median = (
        ordered[midpoint]
        if count % 2
        else (ordered[midpoint - 1] + ordered[midpoint]) / 2.0
    )
    p95_index = max(0, math.ceil(0.95 * count) - 1)
    return {
        "count": count,
        "median_seconds": median,
        "p95_seconds": ordered[p95_index],
        "max_seconds": ordered[-1],
    }


def write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_suffix(path.suffix + ".tmp")
    temp_path.write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temp_path.replace(path)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    android = subparsers.add_parser("android", help="collect an Android snapshot")
    android.add_argument("--serial", required=True)
    android.add_argument("--output", type=Path, required=True)
    android.add_argument("--require-16k", action="store_true")
    android.add_argument("--require-battery-ready", action="store_true")

    macos = subparsers.add_parser("macos", help="collect a macOS snapshot")
    macos.add_argument("--app-path", type=Path, required=True)
    macos.add_argument("--output", type=Path, required=True)

    timings = subparsers.add_parser("timings", help="summarize timing samples")
    timings.add_argument("samples", nargs="+", type=float)
    timings.add_argument("--output", type=Path, required=True)
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.command == "android":
        snapshot = collect_android_snapshot(args.serial)
        snapshot["acceptance"] = android_acceptance_verdict(snapshot)
        write_json_atomic(args.output, snapshot)
        if args.require_16k and not snapshot["acceptance"]["android_16k_hardware"]:
            return 2
        if (
            args.require_battery_ready
            and not snapshot["acceptance"]["battery_baseline_ready"]
        ):
            return 2
        return 0
    if args.command == "macos":
        write_json_atomic(
            args.output,
            collect_macos_snapshot(args.app_path.expanduser().resolve()),
        )
        return 0
    write_json_atomic(args.output, summarize_timings(args.samples))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
