#!/usr/bin/env python3
"""Verify the bundled smart-rule manifest without network access."""

from __future__ import annotations

import hashlib
import sys
import base64
import subprocess
import tempfile
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
    "cn.yaml": "domain",
    "gfw.yaml": "domain",
    "direct_apps.yaml": "packages",
    "proxy_apps.yaml": "packages",
}
EXPECTED_DIRECTORY_FILES = set(EXPECTED_FILES) | {"manifest.json", "version.json"}
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
        "+.autohome.com",
        "+.autohome.com.cn",
        "+.bitauto.com",
        "+.che168.com",
        "+.yiche.com",
    },
    "user_feedback_rules.yaml": {
        "+.services.googleapis.cn",
        "+.xn--ngstr-lra8j.com",
    },
}


def load_payload(path: Path, behavior: str) -> list[str]:
    sys.path.insert(0, str(ROOT / 'rule-channel'))
    from publish import read_payload
    return read_payload(path.read_text(encoding='utf-8'), behavior)


def main() -> int:
    manifest_path = RULE_DIR / "manifest.json"
    actual_files = {path.name for path in RULE_DIR.iterdir() if path.is_file()}
    if actual_files != EXPECTED_DIRECTORY_FILES:
        raise SystemExit(
            "smart-rule directory file set is incomplete or unexpected: "
            f"{sorted(actual_files)}"
        )
    manifest_content = manifest_path.read_bytes()
    if len(manifest_content) > 64 * 1024:
        raise SystemExit("smart-rule manifest exceeds the 64 KiB limit")
    manifest = json.loads(manifest_content)
    if manifest.get("schemaVersion") != 1:
        raise SystemExit("smart-rule manifest schemaVersion must be 1")
    version = manifest.get("version")
    if not isinstance(version, str) or not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise SystemExit("smart-rule manifest version is invalid")

    version_path = RULE_DIR / "version.json"
    version_content = version_path.read_bytes()
    if not version_content or len(version_content) > 4 * 1024:
        raise SystemExit("smart-rule version descriptor size is invalid")
    descriptor = json.loads(version_content)
    if descriptor.get("schemaVersion") != 1:
        raise SystemExit("smart-rule version descriptor schemaVersion must be 1")
    if descriptor.get("version") != version:
        raise SystemExit("smart-rule version descriptor does not match manifest")
    if descriptor.get("manifestSha256") != hashlib.sha256(manifest_content).hexdigest():
        raise SystemExit("smart-rule version descriptor manifest SHA256 mismatch")
    versions = manifest.get('componentVersions', {})
    if set(versions) != {'rules', 'directApps', 'proxyApps'} or any(
        not isinstance(v, str) or not re.fullmatch(r'\d+\.\d+\.\d+', v) for v in versions.values()
    ):
        raise SystemExit('invalid independent component versions')
    with tempfile.TemporaryDirectory() as temporary:
        message = Path(temporary) / 'message'
        signature = Path(temporary) / 'signature'
        message.write_text(f'SSRVPN rules v1\n{version}\n{descriptor["manifestSha256"]}\n')
        signature.write_bytes(base64.b64decode(descriptor['signature'], validate=True))
        subprocess.run(['openssl', 'pkeyutl', '-verify', '-rawin', '-pubin', '-inkey',
                        str(ROOT / 'rule-channel/public-key.pem'), '-in', str(message),
                        '-sigfile', str(signature)], check=True, stdout=subprocess.DEVNULL)
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
        if len(content) > 4 * 1024 * 1024:
            raise SystemExit(f"{name}: exceeds the 4 MiB provider limit")
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
        if "# version:" in text:
            raise SystemExit(
                f"{name}: channel version belongs only in manifest/version.json"
            )

    print(f"Smart-rule bundle verified: {version}, {len(EXPECTED_FILES)} files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
