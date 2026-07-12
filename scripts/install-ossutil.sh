#!/usr/bin/env bash
set -euo pipefail

version=2.3.0
archive="ossutil-${version}-linux-amd64.zip"
expected_sha256=3ae4d9fc85a7a6e9f5654d1599766f1a3a42a3692870887b5ae9338d582ef65a
install_dir="${1:?install directory is required}"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

curl -fsSLo "$work_dir/$archive" \
  "https://gosspublic.alicdn.com/ossutil/v2/$version/$archive"
printf '%s  %s\n' "$expected_sha256" "$work_dir/$archive" | sha256sum -c -
unzip -q "$work_dir/$archive" -d "$work_dir"
mkdir -p "$install_dir"
install -m 0755 "$work_dir/ossutil-${version}-linux-amd64/ossutil" \
  "$install_dir/ossutil"
