#!/usr/bin/env bash
set -euo pipefail

restore_mode=0
if [ "$#" -eq 2 ] && [ "$1" = "--restore" ]; then
  restore_mode=1
  backup_dir="$2"
elif [ "$#" -eq 2 ]; then
  source_dir="$1"
  manifest="$2"
else
  echo "usage: $0 <asset-directory> <latest.json>" >&2
  echo "       $0 --restore <backup-directory>" >&2
  exit 2
fi

ossutil_bin="${OSSUTIL_BIN:-ossutil}"
curl_bin="${CURL_BIN:-curl}"
: "${OSS_BUCKET:?OSS_BUCKET is required}"
: "${OSS_ENDPOINT:?OSS_ENDPOINT is required}"
: "${OSS_PREFIX:?OSS_PREFIX is required}"

publish_files=(
  SSRVPN.apk SSRVPN.apk.sha256
  SSRVPN.dmg SSRVPN.dmg.sha256
  SSRVPN_Setup.exe SSRVPN_Setup.exe.sha256
)
retired_files=(
  SSRVPN.zip SSRVPN.zip.sha256
)
managed_files=("${publish_files[@]}" "${retired_files[@]}")

if [ "$restore_mode" -eq 0 ]; then
python3 - "$source_dir" "$manifest" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

source = pathlib.Path(sys.argv[1])
manifest = pathlib.Path(sys.argv[2])
data = json.loads(manifest.read_text(encoding="utf-8"))
assets = data.get("assets")
if not isinstance(assets, list):
    raise SystemExit("latest.json has no assets list")
expected = {}
for item in assets:
    if not isinstance(item, dict):
        raise SystemExit("latest.json contains an invalid asset")
    name = item.get("name")
    digest = item.get("sha256")
    if not isinstance(name, str) or not isinstance(digest, str):
        raise SystemExit("latest.json asset metadata is incomplete")
    if not re.fullmatch(r"[a-f0-9]{64}", digest):
        raise SystemExit(f"invalid SHA256 for {name}")
    expected[name] = digest

def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source_file:
        for chunk in iter(lambda: source_file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

for name in ("SSRVPN.apk", "SSRVPN.dmg", "SSRVPN_Setup.exe"):
    path = source / name
    if not path.is_file():
        raise SystemExit(f"missing public asset: {name}")
    actual = sha256(path)
    if expected.get(name) != actual:
        raise SystemExit(f"latest.json SHA256 mismatch for {name}")
    checksum = source / f"{name}.sha256"
    if not checksum.is_file() or actual not in checksum.read_text().lower().split():
        raise SystemExit(f"checksum file mismatch for {name}")
PY
fi

public_base="https://$OSS_BUCKET.$OSS_ENDPOINT"
stable_prefix="$OSS_PREFIX/downloads"
committed=0

object_key() {
  local name="$1"
  if [ "$name" = latest.json ]; then
    printf '%s/latest.json' "$OSS_PREFIX"
  else
    printf '%s/%s' "$stable_prefix" "$name"
  fi
}

download_limit() {
  case "$1" in
    *.sha256) printf '%s' 65536 ;;
    latest.json) printf '%s' 1048576 ;;
    *) printf '%s' 314572800 ;;
  esac
}

fetch_object() {
  local name="$1"
  local destination="$2"
  local key
  key="$(object_key "$name")"
  "$curl_bin" -sS --retry 3 --connect-timeout 10 --max-time 180 \
    --max-filesize "$(download_limit "$name")" -o "$destination" \
    -w '%{http_code}' "$public_base/$key" || true
}

restore_backup() {
  local source_backup="$1"
  if [ ! -f "$source_backup/.ssrvpn-oss-channel-backup" ]; then
    echo "Invalid OSS public-channel backup: $source_backup" >&2
    return 2
  fi

  local name
  for name in "${managed_files[@]}" latest.json; do
    if [ -f "$source_backup/$name.present" ] && [ -f "$source_backup/$name" ]; then
      continue
    fi
    if [ -f "$source_backup/$name.absent" ] && [ ! -e "$source_backup/$name" ]; then
      continue
    fi
    echo "Incomplete OSS public-channel backup entry: $name" >&2
    return 2
  done

  local restore_failed=0
  local key restored attempt verify_status
  for name in "${managed_files[@]}" latest.json; do
    key="$(object_key "$name")"
    restored=0
    for attempt in 1 2 3; do
      if [ -f "$source_backup/$name.present" ]; then
        "$ossutil_bin" cp "$source_backup/$name" "oss://$OSS_BUCKET/$key" \
          --force --cache-control "no-cache" >/dev/null 2>&1
        verify_status="$(fetch_object "$name" "$source_backup/restore-$name")"
        if [ "$verify_status" = 200 ] && \
          cmp -s "$source_backup/$name" "$source_backup/restore-$name"; then
          restored=1
          break
        fi
      else
        "$ossutil_bin" rm "oss://$OSS_BUCKET/$key" --force >/dev/null 2>&1
        verify_status="$(fetch_object "$name" "$source_backup/restore-$name")"
        if [ "$verify_status" = 404 ]; then
          restored=1
          break
        fi
      fi
      sleep "$attempt"
    done
    if [ "$restored" -ne 1 ]; then
      echo "::error::Failed to restore and verify OSS object $name" >&2
      restore_failed=1
    fi
  done
  if [ "$restore_failed" -ne 0 ]; then
    echo "::error::OSS public channel recovery is incomplete. Backups remain at $source_backup" >&2
    return 86
  fi
  rm -rf "$source_backup"
}

if [ "$restore_mode" -eq 1 ]; then
  restore_backup "$backup_dir"
  exit $?
fi

if [ -n "${OSS_BACKUP_DIR:-}" ]; then
  backup_dir="$OSS_BACKUP_DIR"
  if [ -e "$backup_dir" ]; then
    echo "OSS backup path already exists: $backup_dir" >&2
    exit 2
  fi
  mkdir -m 700 "$backup_dir"
else
  backup_dir="$(mktemp -d "${RUNNER_TEMP:-/tmp}/ssrvpn-oss-backup.XXXXXX")"
fi
touch "$backup_dir/.ssrvpn-oss-channel-backup"

restore_previous_channel() {
  local original_status="$?"
  trap - EXIT
  if [ "$committed" -eq 1 ]; then
    rm -rf "$backup_dir"
    exit "$original_status"
  fi
  echo "OSS public promotion failed; restoring the previous channel" >&2
  set +e
  restore_backup "$backup_dir"
  local restore_status="$?"
  if [ "$restore_status" -ne 0 ]; then
    exit "$restore_status"
  fi
  exit "${original_status:-1}"
}
# Until every previous object has been classified as present or absent, a
# recovery routine cannot safely infer what should be restored. A backup read
# failure therefore performs local cleanup only and never mutates OSS.
trap 'rm -rf "$backup_dir"' EXIT

for name in "${managed_files[@]}" latest.json; do
  status="$(fetch_object "$name" "$backup_dir/$name")"
  case "$status" in
    200) touch "$backup_dir/$name.present" ;;
    404)
      rm -f "$backup_dir/$name"
      touch "$backup_dir/$name.absent"
      ;;
    *)
      echo "Cannot back up current OSS object $name (HTTP ${status:-network error})" >&2
      exit 1
      ;;
  esac
done

# All previous states are now known. From this point on any failed write must
# restore the fully captured channel.
trap restore_previous_channel EXIT

for name in "${publish_files[@]}"; do
  source="$source_dir/$name"
  key="$(object_key "$name")"
  "$ossutil_bin" cp "$source" "oss://$OSS_BUCKET/$key" \
    --force --cache-control "no-cache"
  downloaded="$backup_dir/verify-$name"
  status="$(fetch_object "$name" "$downloaded")"
  if [ "$status" != 200 ]; then
    echo "Cannot verify promoted OSS object $name (HTTP ${status:-network error})" >&2
    exit 1
  fi
  cmp "$source" "$downloaded"
done

retired_marker="$backup_dir/windows-portable-retired.txt"
printf '%s\n' \
  'SSRVPN Windows portable distribution retired; use SSRVPN_Setup.exe.' \
  >"$retired_marker"

for name in "${retired_files[@]}"; do
  key="$(object_key "$name")"
  if [ -f "$backup_dir/$name.present" ]; then
    if ! "$ossutil_bin" rm "oss://$OSS_BUCKET/$key" --force; then
      echo "::warning::Cannot delete retired OSS object $name; replacing it with a retirement marker."
    fi
  fi
  status="$(fetch_object "$name" "$backup_dir/verify-retired-$name")"
  if [ "$status" = 404 ]; then
    continue
  fi

  "$ossutil_bin" cp "$retired_marker" "oss://$OSS_BUCKET/$key" \
    --force --cache-control "no-cache"
  status="$(fetch_object "$name" "$backup_dir/verify-retired-$name")"
  if [ "$status" != 200 ] || \
    ! cmp -s "$retired_marker" "$backup_dir/verify-retired-$name"; then
    echo "Cannot safely retire OSS object $name (HTTP ${status:-network error})" >&2
    exit 1
  fi
done

latest_key="$(object_key latest.json)"
"$ossutil_bin" cp "$manifest" "oss://$OSS_BUCKET/$latest_key" \
  --force --cache-control "no-cache"
status="$(fetch_object latest.json "$backup_dir/verify-latest.json")"
if [ "$status" != 200 ]; then
  echo "Cannot verify promoted latest.json (HTTP ${status:-network error})" >&2
  exit 1
fi
cmp "$manifest" "$backup_dir/verify-latest.json"

committed=1
trap - EXIT
if [ "${OSS_PRESERVE_BACKUP:-0}" = 1 ]; then
  echo "OSS public-channel backup preserved at $backup_dir"
else
  rm -rf "$backup_dir"
fi
