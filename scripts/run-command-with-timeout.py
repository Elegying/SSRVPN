#!/usr/bin/env python3
"""Run a command with inherited stdin content and a hard timeout."""

from __future__ import annotations

import argparse
import subprocess
import sys


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("timeout_seconds", type=float)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.timeout_seconds <= 0 or not args.command:
        parser.error("a positive timeout and command are required")
    try:
        result = subprocess.run(
            args.command,
            stdin=sys.stdin.buffer,
            timeout=args.timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired:
        print(
            f"command timed out after {args.timeout_seconds:g}s: {args.command[0]}",
            file=sys.stderr,
        )
        raise SystemExit(124)
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
