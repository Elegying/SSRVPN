#!/usr/bin/env python3
"""Losslessly recompress an APK using SDK tools, retaining its signer and payload."""

import argparse
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import zipfile


def payload(path: Path) -> dict:
    result = {}
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if len(names) != len(set(names)):
            raise ValueError("Duplicate APK entries")
        for entry in archive.infolist():
            # Only signing metadata may change when the same key signs again.
            if re.fullmatch(r"META-INF/(?:MANIFEST\.MF|[^/]+\.(?:SF|RSA|DSA|EC))",
                            entry.filename, re.IGNORECASE):
                continue
            digest = hashlib.sha256()
            with archive.open(entry) as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            result[entry.filename] = (entry.compress_type, entry.file_size,
                                      digest.hexdigest())
    return result


def certificate(signer: Path, apk: Path) -> list[str]:
    output = subprocess.check_output(
        [str(signer), "verify", "--print-certs", str(apk)], text=True)
    digests = re.findall(r"^Signer #\d+ certificate SHA-256 digest: ([0-9a-f]+)$",
                         output, re.MULTILINE)
    if not digests:
        raise ValueError("APK signing certificate was not verified")
    return sorted(digests)


def optimize(source: Path, destination: Path, build_tools: Path,
             keystore: Path, alias: str) -> None:
    if source.resolve() == destination.resolve():
        raise ValueError("Keep the original APK separate from the output")
    for name in ("SSRVPN_APK_STORE_PASSWORD", "SSRVPN_APK_KEY_PASSWORD"):
        if not os.environ.get(name):
            raise ValueError(f"Missing {name}")
    signer = build_tools / "apksigner"
    aligner = build_tools / "zipalign"
    original_certificate = certificate(signer, source)
    original_payload = payload(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".apk-optimize-",
                                     dir=destination.parent) as temporary:
        aligned = Path(temporary) / "aligned.apk"
        signed = Path(temporary) / "signed.apk"
        subprocess.run([str(aligner), "-z", "-P", "16", "4",
                        str(source), str(aligned)], check=True)
        subprocess.run([str(signer), "sign", "--ks", str(keystore),
                        "--ks-key-alias", alias,
                        "--ks-pass", "env:SSRVPN_APK_STORE_PASSWORD",
                        "--key-pass", "env:SSRVPN_APK_KEY_PASSWORD",
                        "--v4-signing-enabled", "false", "--out", str(signed),
                        str(aligned)], check=True)
        subprocess.run([str(aligner), "-c", "-P", "16", "4", str(signed)],
                       check=True)
        if certificate(signer, signed) != original_certificate:
            raise ValueError("APK signer changed during optimization")
        if payload(signed) != original_payload:
            raise ValueError("APK payload changed during optimization")
        before, after = source.stat().st_size, signed.stat().st_size
        if after >= before:
            shutil.copyfile(source, signed)
            after = before
        os.replace(signed, destination)
        print(f"APK lossless compression: {before} -> {after} bytes "
              f"(saved {before - after}); payload and signer verified")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--build-tools", type=Path, required=True)
    parser.add_argument("--keystore", type=Path, required=True)
    parser.add_argument("--alias", required=True)
    args = parser.parse_args()
    optimize(args.source, args.destination, args.build_tools,
             args.keystore, args.alias)
