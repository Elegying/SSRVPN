#!/usr/bin/env python3
"""Verify the bundled smart-rule manifest without network access."""

from __future__ import annotations

import hashlib
import ipaddress
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RULE_DIR = ROOT / "packages" / "ssrvpn_shared" / "assets" / "rules" / "latest"
EXPECTED_FILES = {
    "ai_services.yaml": "domain",
    "foreign_services.yaml": "domain",
    "streaming_services.yaml": "domain",
    "china_domains.yaml": "domain",
    "company_asn.yaml": "ipcidr",
    "user_feedback_rules.yaml": "domain",
}
DOMAIN_VALUE = re.compile(r"^(?:\+\.)?[a-z0-9_*?][a-z0-9._*?+-]*$")
REQUIRED_DOMAIN_MARKERS = {
    "ai_services.yaml": {"+.openai.com", "+.anthropic.com", "+.gemini.google.com"},
    "foreign_services.yaml": {
        "+.google.com",
        "+.telegram.org",
        "+.github.com",
        "+.discord.com",
    },
    "streaming_services.yaml": {"+.youtube.com", "+.netflix.com", "+.spotify.com"},
    "china_domains.yaml": {
        "+.alibaba.com",
        "+.aliyun.com",
        "+.baidu.com",
        "+.qq.com",
        "+.bytedance.com",
        "+.huawei.com",
        "+.xiaomi.com",
        "+.jd.com",
        "+.163.com",
        "+.iflytek.com",
        "+.volcengine.com",
    },
    "user_feedback_rules.yaml": {
        "+.services.googleapis.cn",
        "+.xn--ngstr-lra8j.com",
    },
}


def load_payload(path: Path, behavior: str) -> list[str]:
    values: list[str] = []
    saw_payload = False
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        stripped = raw_line.strip()
        if stripped == "payload:":
            saw_payload = True
            continue
        if not saw_payload or not stripped.startswith("-"):
            continue
        value = json.loads(stripped[1:].strip())
        if not isinstance(value, str) or not value:
            raise SystemExit(f"{path}: payload entries must be non-empty strings")
        if behavior == "domain":
            if value != value.lower() or not DOMAIN_VALUE.fullmatch(value):
                raise SystemExit(f"{path}: invalid domain entry {value!r}")
        elif behavior == "ipcidr":
            try:
                ipaddress.ip_network(value, strict=True)
            except ValueError as error:
                raise SystemExit(f"{path}: invalid CIDR entry {value!r}") from error
        else:
            raise SystemExit(f"{path}: unsupported behavior {behavior!r}")
        values.append(value)
    if not saw_payload or not values:
        raise SystemExit(f"{path}: missing non-empty payload")
    if len(values) != len(set(values)):
        raise SystemExit(f"{path}: duplicate payload entries")
    return values


def main() -> int:
    manifest_path = RULE_DIR / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schemaVersion") != 1:
        raise SystemExit("smart-rule manifest schemaVersion must be 1")
    version = manifest.get("version")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise SystemExit("smart-rule manifest version is invalid")
    upstream = manifest.get("upstream")
    if not isinstance(upstream, dict) or not re.fullmatch(
        r"[0-9a-f]{40}", str(upstream.get("commit", ""))
    ):
        raise SystemExit("smart-rule upstream commit must be immutable")

    entries = manifest.get("files")
    if not isinstance(entries, list):
        raise SystemExit("smart-rule manifest files must be a list")
    by_name = {entry.get("name"): entry for entry in entries if isinstance(entry, dict)}
    if set(by_name) != set(EXPECTED_FILES):
        raise SystemExit("smart-rule manifest file set is incomplete or unexpected")

    for name, behavior in EXPECTED_FILES.items():
        entry = by_name[name]
        if entry.get("behavior") != behavior:
            raise SystemExit(f"{name}: manifest behavior mismatch")
        path = RULE_DIR / name
        content = path.read_bytes()
        if len(content) > 2 * 1024 * 1024:
            raise SystemExit(f"{name}: exceeds the 2 MiB provider limit")
        digest = hashlib.sha256(content).hexdigest()
        if entry.get("sha256") != digest:
            raise SystemExit(f"{name}: SHA256 does not match manifest")
        values = load_payload(path, behavior)
        if entry.get("count") != len(values):
            raise SystemExit(f"{name}: payload count does not match manifest")
        missing = REQUIRED_DOMAIN_MARKERS.get(name, set()).difference(values)
        if missing:
            raise SystemExit(f"{name}: missing required service markers {sorted(missing)}")
        text = content.decode("utf-8")
        if f"# version: {version}\n" not in text:
            raise SystemExit(f"{name}: version header does not match manifest")

    print(f"Smart-rule bundle verified: {version}, {len(EXPECTED_FILES)} files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
