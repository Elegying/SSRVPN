"""Materialize operator build settings without placing them in source control."""
import json
import os
from pathlib import Path
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def prepare(source: str, root: Path = ROOT) -> Path:
    # Full semantic acceptance is performed by the compiled-provider smoke test.
    providers = json.loads(source)
    if not isinstance(providers, list) or not providers:
        raise ValueError("missing configuration")
    config = json.loads((root / "config/ssrvpn-usage-defines.json").read_text())
    config["SSRVPN_USAGE_PROVIDERS"] = source
    target = root / "config/ssrvpn-private-defines.json"
    fd, temporary = tempfile.mkstemp(dir=target.parent, prefix=".defines-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(config, stream, ensure_ascii=False)
            stream.write("\n")
        os.replace(temporary, target)
    finally:
        Path(temporary).unlink(missing_ok=True)
    return target


if __name__ == "__main__":
    try:
        prepare(os.environ.get("SSRVPN_USAGE_PROVIDERS", ""))
    except (OSError, ValueError, TypeError):
        # Exception messages may contain fragments of the private configuration.
        print("Private build configuration is missing or invalid.", file=sys.stderr)
        sys.exit(1)
