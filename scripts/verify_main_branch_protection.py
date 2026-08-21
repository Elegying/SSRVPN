#!/usr/bin/env python3
"""Fail closed unless GitHub main protection matches the reviewed policy."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


class ProtectionError(ValueError):
    pass


_BOOLEAN_RULES = (
    "enforce_admins",
    "required_linear_history",
    "allow_force_pushes",
    "allow_deletions",
    "block_creations",
    "required_conversation_resolution",
    "lock_branch",
    "allow_fork_syncing",
)


def _checks(payload: dict[str, Any]) -> set[tuple[str, int]]:
    status = payload.get("required_status_checks")
    if not isinstance(status, dict):
        raise ProtectionError("required_status_checks is missing")
    raw_checks = status.get("checks")
    if not isinstance(raw_checks, list):
        raise ProtectionError("required checks are missing")
    checks: list[tuple[str, int]] = []
    for entry in raw_checks:
        if not isinstance(entry, dict):
            raise ProtectionError("required checks contain an invalid entry")
        context = entry.get("context")
        app_id = entry.get("app_id")
        if not isinstance(context, str) or not context:
            raise ProtectionError("required checks contain an invalid context")
        if isinstance(app_id, bool) or not isinstance(app_id, int):
            raise ProtectionError("required checks contain an invalid app_id")
        checks.append((context, app_id))
    if len(checks) != len(set(checks)):
        raise ProtectionError("required checks contain duplicates")
    return set(checks)


def verify(expected: dict[str, Any], actual: dict[str, Any]) -> None:
    expected_status = expected.get("required_status_checks")
    actual_status = actual.get("required_status_checks")
    if not isinstance(expected_status, dict) or not isinstance(actual_status, dict):
        raise ProtectionError("required_status_checks is missing")
    if actual_status.get("strict") is not expected_status.get("strict"):
        raise ProtectionError("required_status_checks.strict does not match")
    if _checks(actual) != _checks(expected):
        raise ProtectionError("required checks do not match the reviewed set")

    for rule in _BOOLEAN_RULES:
        expected_value = expected.get(rule)
        actual_rule = actual.get(rule)
        actual_value = (
            actual_rule.get("enabled") if isinstance(actual_rule, dict) else None
        )
        if not isinstance(expected_value, bool) or actual_value is not expected_value:
            raise ProtectionError(f"{rule} does not match")

    expected_reviews = expected.get("required_pull_request_reviews")
    actual_reviews = actual.get("required_pull_request_reviews")
    if not isinstance(expected_reviews, dict) or not isinstance(actual_reviews, dict):
        raise ProtectionError("required_pull_request_reviews is missing")
    for rule, expected_value in expected_reviews.items():
        if actual_reviews.get(rule) != expected_value:
            raise ProtectionError(
                f"required_pull_request_reviews.{rule} does not match"
            )

    if expected.get("restrictions") is not None or actual.get("restrictions") is not None:
        raise ProtectionError("restrictions must remain null")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected", required=True, type=Path)
    args = parser.parse_args()
    try:
        expected = json.loads(args.expected.read_text(encoding="utf-8"))
        actual = json.load(sys.stdin)
        if not isinstance(expected, dict) or not isinstance(actual, dict):
            raise ProtectionError("protection payload must be a JSON object")
        verify(expected, actual)
    except (OSError, json.JSONDecodeError, ProtectionError) as error:
        raise SystemExit(f"Main branch protection check failed: {error}") from error
    print("ok main branch protection: exact policy and nine required checks")


if __name__ == "__main__":
    main()
