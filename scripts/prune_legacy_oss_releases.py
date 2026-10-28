#!/usr/bin/env python3
"""Retire pre-6.0.0 OSS release objects, preserving pinned installer fixtures."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
BUCKET = "nikuaimobi"
PREFIX = "ssrvpn/releases/"


def command(*arguments):
    return subprocess.run(arguments, check=True, capture_output=True, text=True,
                          timeout=120).stdout


def xml_api(operation, *arguments):
    raw = command("ossutil", "api", operation, "--bucket", BUCKET,
                  *arguments, "--output-format", "xml")
    root = ET.fromstring(raw)
    for node in root.iter():
        node.tag = node.tag.rsplit("}", 1)[-1]
    return root


def protected_keys():
    sources = json.loads((ROOT / "scripts/windows_legacy_installer_sources.json").read_text())
    tags = {source["tag"] for source in sources} | {"v5.0.19"}
    if any(not re.fullmatch(r"v[0-9]+\.[0-9]+\.[0-9]+", tag) for tag in tags):
        raise ValueError("Invalid pinned baseline tag")
    return {f"{PREFIX}{tag}/SSRVPN_Setup.exe" for tag in tags}


def eligible(key, protected):
    match = re.fullmatch(r"ssrvpn/releases/v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)/([A-Za-z0-9_.-]+)", key)
    return bool(match and int(match[1]) < 6 and match[4] not in (".", "..")
                and key not in protected)


def inventory():
    result, tokens, token = {}, set(), ""
    while True:
        arguments = ["--prefix", PREFIX, "--max-keys", "1000"]
        if token:
            arguments += ["--continuation-token", token]
        root = xml_api("list-objects-v2", *arguments)
        if root.tag != "ListBucketResult" or root.findtext("Prefix") != PREFIX:
            raise ValueError("Unexpected OSS inventory scope")
        for item in root.findall("Contents"):
            key, size = item.findtext("Key"), item.findtext("Size")
            if not key or not key.startswith(PREFIX) or key in result or not size or not size.isdigit():
                raise ValueError("Malformed or duplicate object")
            result[key] = int(size)
        truncated = root.findtext("IsTruncated")
        if truncated == "false":
            return result
        token = root.findtext("NextContinuationToken")
        if truncated != "true" or not token or token in tokens:
            raise ValueError("Invalid OSS pagination")
        tokens.add(token)


def verify_channel(tag):
    match = re.fullmatch(r"v([1-9][0-9]*)\.[0-9]+\.[0-9]+", tag)
    if not match or int(match[1]) < 6:
        raise ValueError("Expected a retained public release tag")
    latest = json.loads(command("gh", "api", "repos/Elegying/SSRVPN/releases/latest"))
    if latest.get("tag_name") != tag or latest.get("draft") is not False or latest.get("prerelease") is not False:
        raise ValueError("GitHub latest does not match the accepted public release")
    manifest = command("ossutil", "cat", f"oss://{BUCKET}/ssrvpn/latest.json")
    if json.loads(manifest).get("version") != tag[1:]:
        raise ValueError("OSS latest does not match GitHub")
    return latest["id"], manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    expected = {"GITHUB_REPOSITORY": "Elegying/SSRVPN", "GITHUB_REF": "refs/heads/main",
                "GITHUB_EVENT_NAME": "workflow_dispatch", "OSS_BUCKET": BUCKET,
                "OSS_PREFIX": "ssrvpn", "OSS_ENDPOINT": "oss-cn-qingdao.aliyuncs.com"}
    if any(os.environ.get(key) != value for key, value in expected.items()):
        raise ValueError("Cleanup requires the canonical manual main environment")
    identity = verify_channel(args.tag)
    versioning = xml_api("get-bucket-versioning")
    if versioning.tag != "VersioningConfiguration" or versioning.findtext("Status"):
        raise ValueError("Versioned bucket requires a separate version-aware cleanup")
    before, protected = inventory(), protected_keys()
    selected = {key: size for key, size in before.items() if eligible(key, protected)}
    report = {"tag": args.tag, "apply": args.apply, "objects": selected,
              "selectedBytes": sum(selected.values()),
              "retainedBaselines": sorted(set(before) & protected), "deleted": []}
    target = Path(args.report)
    target.parent.mkdir(parents=True, exist_ok=True)
    def save():
        target.write_text(json.dumps(report, indent=2) + "\n")
    save()
    if args.apply:
        for key in selected:
            if verify_channel(args.tag) != identity:
                raise ValueError("Public channel changed during cleanup")
            # Delete exact inventoried keys only; no recursive or wildcard removal.
            command("ossutil", "api", "delete-object", "--bucket", BUCKET, "--key", key)
            report["deleted"].append(key)
            save()
        after = inventory()
        if any(key in after for key in selected) or any(
                after.get(key) != size for key, size in before.items() if key not in selected):
            raise ValueError("Post-cleanup inventory does not match the plan")
        if verify_channel(args.tag) != identity:
            raise ValueError("Public channel changed after cleanup")
    print(json.dumps({"selectedObjects": len(selected), "selectedBytes": sum(selected.values()),
                      "deletedObjects": len(report["deleted"])}))


if __name__ == "__main__":
    main()
