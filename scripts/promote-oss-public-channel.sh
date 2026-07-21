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
published_binaries=(SSRVPN.apk SSRVPN.dmg SSRVPN_Setup.exe)
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
    -H 'Cache-Control: no-cache' -H 'Pragma: no-cache' \
    -w '%{http_code}' \
    "$public_base/$key?ssrvpn_nocache=$$-$RANDOM-$name" || true
}

copy_object_authoritatively() {
  local name="$1"
  local destination="$2"
  local key
  key="$(object_key "$name")"
  rm -f "$destination"
  "$ossutil_bin" cp "oss://$OSS_BUCKET/$key" "$destination" \
    --force >/dev/null 2>&1
}

object_is_authoritatively_absent() {
  local name="$1"
  local scratch="$2"
  local key
  key="$(object_key "$name")"
  rm -f "$scratch.stat-output" "$scratch.stat-error"
  if "$ossutil_bin" stat "oss://$OSS_BUCKET/$key" \
      >"$scratch.stat-output" 2>"$scratch.stat-error"; then
    return 1
  fi
  grep -Eq '(^|[^[:alnum:]_])NoSuchKey([^[:alnum:]_]|$)' \
    "$scratch.stat-output" "$scratch.stat-error"
}

put_and_verify_object() {
  local name="$1"
  local source="$2"
  local scratch="$3"
  local key attempt
  key="$(object_key "$name")"
  for attempt in 1 2 3; do
    if "$ossutil_bin" cp "$source" "oss://$OSS_BUCKET/$key" \
        --force --cache-control "no-cache" >/dev/null 2>&1; then
      :
    fi
    if copy_object_authoritatively "$name" "$scratch" && \
        cmp -s "$source" "$scratch"; then
      return 0
    fi
    sleep "$attempt"
  done
  return 1
}

remove_and_verify_object() {
  local name="$1"
  local scratch="$2"
  local key attempt
  key="$(object_key "$name")"
  for attempt in 1 2 3; do
    if "$ossutil_bin" rm "oss://$OSS_BUCKET/$key" --force \
        >/dev/null 2>&1; then
      :
    fi
    if object_is_authoritatively_absent "$name" "$scratch"; then
      return 0
    fi
    sleep "$attempt"
  done
  return 1
}

restore_saved_object() {
  local name="$1"
  local source_backup="$2"
  if [ -f "$source_backup/$name.present" ]; then
    put_and_verify_object \
      "$name" "$source_backup/$name" "$source_backup/restore-$name"
  else
    remove_and_verify_object "$name" "$source_backup/restore-$name"
  fi
}

saved_object_matches() {
  local name="$1"
  local source_backup="$2"
  local scratch="$3"
  if [ -f "$source_backup/$name.present" ]; then
    copy_object_authoritatively "$name" "$scratch" && \
      cmp -s "$source_backup/$name" "$scratch"
  else
    object_is_authoritatively_absent "$name" "$scratch"
  fi
}

pair_is_consistent() {
  local binary="$1"
  local scratch="$2"
  local checksum="$binary.sha256"
  if copy_object_authoritatively "$binary" "$scratch/$binary.current"; then
    copy_object_authoritatively \
      "$checksum" "$scratch/$checksum.current" || return 1
    python3 - \
      "$scratch/$binary.current" "$scratch/$checksum.current" <<'PY'
import hashlib
import pathlib
import sys

binary = pathlib.Path(sys.argv[1])
checksum = pathlib.Path(sys.argv[2])
expected = hashlib.sha256(binary.read_bytes()).hexdigest()
try:
    tokens = checksum.read_text(encoding="utf-8").lower().split()
except (OSError, UnicodeError):
    raise SystemExit(1)
raise SystemExit(0 if expected in tokens else 1)
PY
    return $?
  fi
  object_is_authoritatively_absent "$binary" "$scratch/$binary.absent" && \
    object_is_authoritatively_absent \
      "$checksum" "$scratch/$checksum.absent"
}

validate_backup_pair() {
  local binary="$1"
  local source_backup="$2"
  local checksum="$binary.sha256"
  if [ -f "$source_backup/$binary.present" ] && \
      [ -f "$source_backup/$checksum.present" ]; then
    python3 - "$source_backup/$binary" "$source_backup/$checksum" <<'PY'
import hashlib
import pathlib
import sys

binary = pathlib.Path(sys.argv[1])
checksum = pathlib.Path(sys.argv[2])
expected = hashlib.sha256(binary.read_bytes()).hexdigest()
try:
    tokens = checksum.read_text(encoding="utf-8").lower().split()
except (OSError, UnicodeError):
    raise SystemExit(1)
raise SystemExit(0 if expected in tokens else 1)
PY
    return $?
  fi
  [ -f "$source_backup/$binary.absent" ] && \
    [ -f "$source_backup/$checksum.absent" ]
}

restore_published_pair() {
  local binary="$1"
  local source_backup="$2"
  local checksum="$binary.sha256"

  if ! restore_saved_object "$binary" "$source_backup"; then
    echo "::error::Failed to restore and verify OSS object $binary" >&2
    return 1
  fi

  if restore_saved_object "$checksum" "$source_backup" && \
      pair_is_consistent "$binary" "$source_backup"; then
    return 0
  fi

  echo "::error::Failed to restore and verify OSS object $checksum" >&2
  return 1
}

capture_channel_snapshot() {
  local snapshot="$1"
  local name
  rm -rf "$snapshot"
  mkdir -m 700 "$snapshot"
  for name in "${managed_files[@]}" latest.json; do
    if copy_object_authoritatively "$name" "$snapshot/$name"; then
      touch "$snapshot/$name.present"
    elif object_is_authoritatively_absent \
        "$name" "$snapshot/classify-$name"; then
      rm -f "$snapshot/$name"
      touch "$snapshot/$name.absent"
    else
      echo "::error::Cannot capture current OSS object $name before recovery" >&2
      return 1
    fi
  done
}

channel_matches_snapshot() {
  local snapshot="$1"
  local name
  for name in "${managed_files[@]}" latest.json; do
    if ! saved_object_matches \
        "$name" "$snapshot" "$snapshot/match-$name"; then
      return 1
    fi
  done
}

cleanup_backup_scratch() {
  local source_backup="$1"
  rm -f \
    "$source_backup"/restore-* \
    "$source_backup"/match-* \
    "$source_backup"/verify-* \
    "$source_backup"/public-* \
    "$source_backup"/classify-* \
    "$source_backup"/*.current \
    "$source_backup"/*.absent.stat-* \
    "$source_backup"/windows-portable-retired.txt
}

restore_channel_snapshot() {
  local snapshot="$1"
  local restore_failed=0
  local name

  # Restore all stable assets before the pointer so readers never observe a
  # pointer to a channel that has not finished rolling back.
  for name in "${managed_files[@]}"; do
    if ! restore_saved_object "$name" "$snapshot"; then
      echo "::error::Failed to roll back OSS object $name" >&2
      restore_failed=1
    fi
  done
  if ! restore_saved_object latest.json "$snapshot"; then
    echo "::error::Failed to roll back OSS object latest.json" >&2
    restore_failed=1
  fi

  if [ "$restore_failed" -eq 0 ] && channel_matches_snapshot "$snapshot"; then
    return 0
  fi
  echo "::error::OSS public channel safety rollback failed" >&2
  return 1
}

restore_backup() {
  local source_backup="$1"
  local remove_source_on_success="${2:-1}"
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

  local binary
  for binary in "${published_binaries[@]}"; do
    if ! validate_backup_pair "$binary" "$source_backup"; then
      echo "Invalid OSS public-channel backup pair: $binary" >&2
      return 2
    fi
  done

  # Recovery is itself a channel-wide transaction. Capture every live object
  # before the first mutation so one failed platform cannot leave successful
  # earlier platforms on the target backup while latest.json stays current.
  # The snapshot intentionally permits an internally inconsistent live pair:
  # normal promotion can fail after a binary write but before its checksum,
  # and the complete target backup must still be allowed to repair it.
  local current_channel="$source_backup/.restore-current-$$-$RANDOM"
  if ! capture_channel_snapshot "$current_channel"; then
    rm -rf "$current_channel"
    echo "::error::OSS public channel recovery could not capture its rollback state" >&2
    return 86
  fi

  local restore_failed=0
  for binary in "${published_binaries[@]}"; do
    if ! restore_published_pair "$binary" "$source_backup"; then
      restore_failed=1
    fi
  done

  for name in "${retired_files[@]}"; do
    if ! restore_saved_object "$name" "$source_backup"; then
      echo "::error::Failed to restore and verify OSS object $name" >&2
      restore_failed=1
    fi
  done

  if [ "$restore_failed" -ne 0 ]; then
    if ! restore_channel_snapshot "$current_channel"; then
      echo "::error::OSS public channel recovery rollback is incomplete" >&2
    fi
    rm -rf "$current_channel"
    cleanup_backup_scratch "$source_backup"
    echo "::error::OSS public channel recovery is incomplete. Backups remain at $source_backup" >&2
    return 86
  fi

  if ! restore_saved_object latest.json "$source_backup"; then
    echo "::error::Failed to restore and verify OSS object latest.json" >&2
    if ! restore_channel_snapshot "$current_channel"; then
      echo "::error::OSS public channel recovery rollback is incomplete" >&2
    fi
    rm -rf "$current_channel"
    cleanup_backup_scratch "$source_backup"
    echo "::error::OSS public channel recovery is incomplete. Backups remain at $source_backup" >&2
    return 86
  fi
  if ! channel_matches_snapshot "$source_backup"; then
    echo "::error::Restored OSS public channel does not match its backup" >&2
    if ! restore_channel_snapshot "$current_channel"; then
      echo "::error::OSS public channel recovery rollback is incomplete" >&2
    fi
    rm -rf "$current_channel"
    cleanup_backup_scratch "$source_backup"
    echo "::error::OSS public channel recovery is incomplete. Backups remain at $source_backup" >&2
    return 86
  fi

  rm -rf "$current_channel"
  cleanup_backup_scratch "$source_backup"
  if [ "$remove_source_on_success" -eq 1 ]; then
    rm -rf "$source_backup"
  fi
}

if [ "$restore_mode" -eq 1 ]; then
  restore_backup "$backup_dir" 1
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
  local remove_backup_after_recovery=1
  if [ "${OSS_PRESERVE_BACKUP:-0}" = 1 ]; then
    remove_backup_after_recovery=0
  fi
  # A failed publish remains a failed operation even when rollback succeeds.
  # Workflows opt in to retaining the authoritative recovery artifact.
  restore_backup "$backup_dir" "$remove_backup_after_recovery"
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
  if copy_object_authoritatively "$name" "$backup_dir/$name"; then
    touch "$backup_dir/$name.present"
  elif object_is_authoritatively_absent \
      "$name" "$backup_dir/classify-$name"; then
    rm -f "$backup_dir/$name"
    touch "$backup_dir/$name.absent"
  else
    echo "Cannot authoritatively back up current OSS object $name" >&2
    exit 1
  fi
done

for binary in "${published_binaries[@]}"; do
  if ! validate_backup_pair "$binary" "$backup_dir"; then
    echo "Invalid OSS public-channel backup pair: $binary" >&2
    exit 1
  fi
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
cleanup_backup_scratch "$backup_dir"
if [ "${OSS_PRESERVE_BACKUP:-0}" = 1 ]; then
  echo "OSS public-channel backup preserved at $backup_dir"
else
  rm -rf "$backup_dir"
fi
