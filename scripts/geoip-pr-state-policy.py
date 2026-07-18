#!/usr/bin/env python3

import sys


def classify_pr_state(state: str) -> str:
    normalized = state.strip().upper()
    if not normalized:
        return "create"
    if normalized == "OPEN":
        return "reuse"
    if normalized in {"CLOSED", "MERGED"}:
        raise ValueError(
            f"GeoIP refresh pull request is {normalized}; "
            "manual review is required before replacing it"
        )
    raise ValueError(f"Unknown GeoIP refresh pull request state: {normalized}")


def main(argv: list[str]) -> int:
    state = argv[1] if len(argv) > 1 else ""
    try:
        print(classify_pr_state(state))
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
