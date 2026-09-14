#!/usr/bin/env python3
"""Prepare a signed independent-channel snapshot and refresh the bundled baseline."""
import argparse
from pathlib import Path
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'rule-channel'))
from publish import build  # noqa: E402

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--key', type=Path, required=True, help='Ed25519 private key outside the repository')
    parser.add_argument('--upstream-commit')
    parser.add_argument('--core', type=Path, required=True, help='Mihomo executable for mandatory rule review')
    args = parser.parse_args()
    build(args.key, args.upstream_commit, core=args.core)
    target = ROOT / 'packages/ssrvpn_shared/assets/rules/latest'
    for source in (ROOT / 'rule-channel/latest').iterdir():
        if source.is_file():
            shutil.copyfile(source, target / source.name)
