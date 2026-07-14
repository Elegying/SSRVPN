#!/usr/bin/env python3
"""Validate optional desktop release-signing configuration without logging secrets."""

from __future__ import annotations

import argparse
import base64
import binascii
import os
from collections.abc import Mapping


PLATFORMS = {
    "macos": {
        "enabled": "MACOS_SIGNING_ENABLED",
        "required": (
            "MACOS_CERTIFICATE_P12_BASE64",
            "MACOS_CERTIFICATE_PASSWORD",
            "MACOS_SIGNING_IDENTITY",
            "APPLE_NOTARY_APPLE_ID",
            "APPLE_NOTARY_TEAM_ID",
            "APPLE_NOTARY_PASSWORD",
        ),
        "base64": "MACOS_CERTIFICATE_P12_BASE64",
    },
    "windows": {
        "enabled": "WINDOWS_SIGNING_ENABLED",
        "required": (
            "WINDOWS_CERTIFICATE_PFX_BASE64",
            "WINDOWS_CERTIFICATE_PASSWORD",
        ),
        "base64": "WINDOWS_CERTIFICATE_PFX_BASE64",
    },
}

TRUE_VALUES = {"true"}
FALSE_VALUES = {"", "false"}


class SigningConfigurationError(ValueError):
    """Raised when explicitly enabled signing is incomplete or malformed."""


def validate(platform: str, environment: Mapping[str, str]) -> bool:
    """Return whether signing is enabled, or raise for an unsafe configuration."""

    config = PLATFORMS[platform]
    enabled_name = config["enabled"]
    raw_enabled = environment.get(enabled_name, "").strip()
    if raw_enabled in FALSE_VALUES:
        return False
    if raw_enabled not in TRUE_VALUES:
        raise SigningConfigurationError(
            f"{enabled_name} must be true or false, not an arbitrary value"
        )

    missing = [
        name for name in config["required"] if not environment.get(name, "").strip()
    ]
    if missing:
        raise SigningConfigurationError(
            f"{platform} signing is enabled but required variables are missing: "
            + ", ".join(missing)
        )

    encoded_name = config["base64"]
    try:
        decoded = base64.b64decode(environment[encoded_name], validate=True)
    except (binascii.Error, ValueError) as error:
        raise SigningConfigurationError(
            f"{encoded_name} is not valid Base64"
        ) from error
    if not decoded:
        raise SigningConfigurationError(f"{encoded_name} decodes to an empty file")

    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("platform", choices=sorted(PLATFORMS))
    args = parser.parse_args()

    try:
        enabled = validate(args.platform, os.environ)
    except SigningConfigurationError as error:
        parser.error(str(error))

    state = "enabled and complete" if enabled else "disabled"
    print(f"{args.platform} release signing: {state}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
