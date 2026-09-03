#!/usr/bin/env python3
"""Build SSRVPN's reviewed smart-routing snapshots from pinned upstream data."""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import re
import urllib.request
from collections import OrderedDict
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT_DIR = ROOT / "packages" / "ssrvpn_shared" / "assets" / "rules" / "latest"
RULE_VERSION = "1.1.0"
UPSTREAM_COMMIT = "200e6a86736cfab29aae7b07dc266e59f13bc13d"
RAW_BASE = (
    "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/"
    f"{UPSTREAM_COMMIT}"
)

DOMAIN_GROUPS: OrderedDict[str, tuple[str, ...]] = OrderedDict(
    {
        "ai_services.yaml": ("openai", "anthropic", "google-gemini"),
        "foreign_services.yaml": ("google", "telegram", "github", "discord"),
        "streaming_services.yaml": (
            "youtube",
            "netflix",
            "spotify",
            "twitch",
            "tiktok",
        ),
        "china_domains.yaml": (
            "alibaba",
            "alibabacloud",
            "aliyun",
            "baidu",
            "tencent",
            "bytedance",
            "huawei",
            "huaweicloud",
            "xiaomi",
            "jd",
            "netease",
            "iflytek",
            "volcengine",
            "category-ai-cn",
        ),
    }
)

# These are outage fixes promoted from user reports. They intentionally stay
# small and proxy-only; a bad emergency entry can therefore be rolled back by
# reverting the rules channel without changing the client binary.
USER_FEEDBACK_PROXY_DOMAINS = (
    "+.services.googleapis.cn",
    "+.xn--ngstr-lra8j.com",
)

# Conservative additions for established domestic travel/automotive services.
# Domain matching stays above ASN/GeoIP so their overseas CDN endpoints remain
# direct without broadening the policy to shared hosting providers.
REVIEWED_CHINA_SERVICE_DOMAINS = (
    "+.autohome.com",
    "+.autohome.com.cn",
    "+.bitauto.com",
    "+.che168.com",
    "+.yiche.com",
)

# PeeringDB organization/network records reviewed on 2026-09-02. The runtime
# uses the pinned upstream ASN-to-prefix expansion instead of downloading a
# mutable ASN database. Shared hosting is why this set is deliberately narrow.
COMPANY_ASNS: OrderedDict[str, tuple[int, ...]] = OrderedDict(
    {
        "Alibaba": (45102, 37963, 24429),
        "Tencent": (132203, 45090),
        "Baidu": (55967, 38365),
        "ByteDance": (138699, 396986),
    }
)

DOMAIN_VALUE = re.compile(r"^(?:\+\.)?[A-Za-z0-9_*?][A-Za-z0-9._*?+-]*$")
CIDR_VALUE = re.compile(r"^[0-9A-Fa-f:.]+/\d{1,3}$")


def fetch_text(path: str) -> str:
    request = urllib.request.Request(
        f"{RAW_BASE}/{path}",
        headers={"User-Agent": "SSRVPN-smart-rule-builder/1"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        if response.status != 200:
            raise RuntimeError(f"unexpected HTTP {response.status}: {path}")
        data = response.read(4 * 1024 * 1024 + 1)
    if len(data) > 4 * 1024 * 1024:
        raise RuntimeError(f"upstream rule file is too large: {path}")
    return data.decode("utf-8")


def parse_yaml_payload(text: str, source: str) -> list[str]:
    values: list[str] = []
    in_payload = False
    for raw_line in text.splitlines():
        stripped = raw_line.strip()
        if stripped == "payload:":
            in_payload = True
            continue
        if not in_payload or not stripped.startswith("-"):
            continue
        scalar = stripped[1:].strip()
        if not scalar:
            raise RuntimeError(f"empty payload entry in {source}")
        if scalar[0] in "'\"":
            try:
                parsed = ast.literal_eval(scalar)
            except (SyntaxError, ValueError) as error:
                raise RuntimeError(f"invalid quoted payload in {source}") from error
            if not isinstance(parsed, str):
                raise RuntimeError(f"non-string payload in {source}")
            scalar = parsed
        if not DOMAIN_VALUE.fullmatch(scalar):
            raise RuntimeError(f"unsupported domain payload {scalar!r} in {source}")
        values.append(scalar.lower())
    if not values:
        raise RuntimeError(f"no payload entries found in {source}")
    return values


def parse_cidr_list(text: str, source: str) -> list[str]:
    values: list[str] = []
    for raw_line in text.splitlines():
        scalar = raw_line.strip()
        if not scalar or scalar.startswith("#"):
            continue
        if not CIDR_VALUE.fullmatch(scalar):
            raise RuntimeError(f"unsupported CIDR payload {scalar!r} in {source}")
        values.append(scalar)
    if not values:
        raise RuntimeError(f"no CIDR entries found in {source}")
    return values


def unique(values: list[str]) -> list[str]:
    return list(dict.fromkeys(values))


def render_payload(values: list[str], *, kind: str, sources: list[str]) -> bytes:
    lines = [
        "# SSRVPN smart-routing rule snapshot",
        f"# upstream: MetaCubeX/meta-rules-dat@{UPSTREAM_COMMIT}",
        f"# kind: {kind}",
        f"# sources: {', '.join(sources)}",
        "payload:",
    ]
    lines.extend(f"  - {json.dumps(value, ensure_ascii=False)}" for value in values)
    return ("\n".join(lines) + "\n").encode("utf-8")


def build() -> tuple[dict[str, bytes], dict[str, object]]:
    generated: dict[str, bytes] = {}
    file_metadata: list[dict[str, object]] = []

    for filename, categories in DOMAIN_GROUPS.items():
        values: list[str] = []
        sources: list[str] = []
        for category in categories:
            source = f"geo/geosite/{category}.yaml"
            sources.append(source)
            values.extend(parse_yaml_payload(fetch_text(source), source))
        if filename == "china_domains.yaml":
            sources.append("SSRVPN reviewed domestic services")
            values.extend(REVIEWED_CHINA_SERVICE_DOMAINS)
        values = unique(values)
        content = render_payload(values, kind="domain", sources=sources)
        generated[filename] = content
        file_metadata.append(
            {
                "name": filename,
                "behavior": "domain",
                "count": len(values),
                "sha256": hashlib.sha256(content).hexdigest(),
            }
        )

    feedback_sources = ["SSRVPN reviewed user feedback"]
    feedback_content = render_payload(
        list(USER_FEEDBACK_PROXY_DOMAINS),
        kind="domain",
        sources=feedback_sources,
    )
    generated["user_feedback_rules.yaml"] = feedback_content
    file_metadata.append(
        {
            "name": "user_feedback_rules.yaml",
            "behavior": "domain",
            "count": len(USER_FEEDBACK_PROXY_DOMAINS),
            "sha256": hashlib.sha256(feedback_content).hexdigest(),
        }
    )

    cidrs: list[str] = []
    asn_sources: list[str] = []
    for company, asns in COMPANY_ASNS.items():
        for asn in asns:
            source = f"asn/AS{asn}.list"
            asn_sources.append(f"{company}:AS{asn}")
            cidrs.extend(parse_cidr_list(fetch_text(source), source))
    cidrs = unique(cidrs)
    cidr_content = render_payload(cidrs, kind="ipcidr", sources=asn_sources)
    generated["company_asn.yaml"] = cidr_content
    file_metadata.append(
        {
            "name": "company_asn.yaml",
            "behavior": "ipcidr",
            "count": len(cidrs),
            "sha256": hashlib.sha256(cidr_content).hexdigest(),
        }
    )

    manifest: dict[str, object] = {
        "schemaVersion": 1,
        "version": RULE_VERSION,
        "upstream": {
            "repository": "MetaCubeX/meta-rules-dat",
            "commit": UPSTREAM_COMMIT,
        },
        "files": file_metadata,
        "companyAsns": {name: list(asns) for name, asns in COMPANY_ASNS.items()},
        "rollback": (
            "Republish the last known-good content under a higher rule version; "
            "clients reject downgrades and retain valid local providers on failure."
        ),
    }
    return generated, manifest


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--output",
        type=Path,
        default=OUTPUT_DIR,
        help="output directory for the generated snapshot",
    )
    args = parser.parse_args()

    generated, manifest = build()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    for filename, content in generated.items():
        (output / filename).write_bytes(content)
    manifest_content = (
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    ).encode("utf-8")
    (output / "manifest.json").write_bytes(manifest_content)
    version_descriptor = {
        "schemaVersion": 1,
        "version": RULE_VERSION,
        "manifestSha256": hashlib.sha256(manifest_content).hexdigest(),
    }
    (output / "version.json").write_text(
        json.dumps(version_descriptor, ensure_ascii=False, separators=(",", ":")) + "\n",
        encoding="utf-8",
    )
    print(f"wrote SSRVPN smart rules {RULE_VERSION} to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
