#!/bin/bash
set -euo pipefail

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
LC_ALL=C
export LC_ALL
umask 077

status_path=

write_status() {
  [[ -n ${status_path:-} ]] || return 0
  /usr/bin/printf '%s\n' "$1" > "$status_path"
  /bin/chmod 644 "$status_path"
}

die() {
  if [[ -n ${status_path:-} ]]; then
    write_status "error:runner" || true
  fi
  echo "SSRVPN TUN: $*" >&2
  exit 1
}

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "administrator authorization is required"
recovery_only=false
staged_config=
expected_request_value=
if [[ $# -eq 6 && $1 == "--app-pid" && $2 =~ ^[0-9]+$ && $2 -gt 1 && \
      $3 == "--staged-config" && $5 == "--request-token" ]]; then
  app_pid=$2
  staged_config=$4
  expected_request_value=$6
elif [[ $# -eq 3 && $1 == "--recover-dns" && $2 == "--app-pid" && \
        $3 =~ ^[0-9]+$ && $3 -gt 1 ]]; then
  recovery_only=true
  app_pid=$3
else
  die "invalid arguments"
fi
status_path="/var/run/ssrvpn-tun-status-$app_pid"
if [[ -e $status_path || -L $status_path ]]; then
  [[ -f $status_path && ! -L $status_path && \
      $(/usr/bin/stat -f '%u' "$status_path") == 0 ]] || \
    die "unsafe TUN status path"
else
  (set -o noclobber; : > "$status_path") 2>/dev/null || \
    die "cannot create TUN status file"
fi
write_status "starting"

console_user=$(/usr/bin/stat -f '%Su' /dev/console)
[[ -n $console_user && $console_user != root && $console_user != loginwindow ]] || \
  die "no active console user"
user_id=$(/usr/bin/id -u "$console_user")
app_owner=$(/bin/ps -p "$app_pid" -o uid= | /usr/bin/tr -d ' ')
[[ $app_owner == "$user_id" ]] || die "the requesting app is not owned by the console user"

home_line=$(/usr/bin/dscl . -read "/Users/$console_user" NFSHomeDirectory)
user_home=${home_line#*: }
[[ $user_home == /* && -d $user_home && ! -L $user_home ]] || die "invalid user home"

request_name=.tun-session-request
data_dir=
request_paths=()
for candidate in \
  "$user_home/Library/Application Support/SSRVPN" \
  "$user_home/Library/Application Support/com.ssrvpn.ssrvpnClient/SSRVPN"; do
  [[ -d $candidate && ! -L $candidate && \
      $(/usr/bin/stat -f '%u' "$candidate") == "$user_id" ]] || continue
  candidate_request="$candidate/$request_name"
  if [[ -e $candidate_request || -L $candidate_request ]]; then
    [[ -f $candidate_request && ! -L $candidate_request && \
        $(/usr/bin/stat -f '%u' "$candidate_request") == "$user_id" ]] || \
      die "unsafe TUN request path"
    request_paths+=("$candidate_request")
    [[ -n $data_dir ]] || data_dir=$candidate
  fi
done
[[ -n $data_dir && -d $data_dir && ! -L $data_dir ]] || die "invalid SSRVPN data directory"
[[ $(/usr/bin/stat -f '%u' "$data_dir") == "$user_id" ]] || die "data directory owner mismatch"

request_path="$data_dir/$request_name"
request_size=$(/usr/bin/stat -f '%z' "$request_path")
request_value=$(/bin/cat "$request_path") || die "cannot read TUN request"
[[ $request_size =~ ^[0-9]+$ && $request_size -le 64 && \
    $request_size -eq $((${#request_value} + 1)) ]] || \
  die "invalid TUN recovery request"
request_format=
request_phase=
request_app_pid=
request_nonce=
if [[ $request_value =~ ^v2:(active|recovery):([0-9]+):([0-9a-f]{32})$ ]]; then
  request_format=v2
  request_phase=${BASH_REMATCH[1]}
  request_app_pid=${BASH_REMATCH[2]}
  request_nonce=${BASH_REMATCH[3]}
elif [[ $request_value =~ ^[0-9]+$ ]]; then
  request_format=legacy
  request_app_pid=$request_value
else
  die "invalid TUN recovery request"
fi
[[ $request_app_pid -gt 1 ]] || die "invalid TUN recovery request"
request_values=("$request_value")
for candidate_request in "${request_paths[@]}"; do
  [[ $candidate_request == "$request_path" ]] && continue
  candidate_size=$(/usr/bin/stat -f '%z' "$candidate_request") || \
    die "cannot inspect TUN request"
  candidate_value=$(/bin/cat "$candidate_request") || \
    die "cannot read TUN request"
  [[ $candidate_size =~ ^[0-9]+$ && $candidate_size -le 64 && \
      $candidate_size -eq $((${#candidate_value} + 1)) ]] || \
    die "invalid TUN recovery request"
  if [[ $candidate_value =~ ^v2:(active|recovery):([0-9]+):[0-9a-f]{32}$ ]]; then
    [[ ${BASH_REMATCH[2]} -gt 1 ]] || die "invalid TUN recovery request"
  elif [[ $candidate_value =~ ^[0-9]+$ && $candidate_value -gt 1 ]]; then
    :
  else
    die "invalid TUN recovery request"
  fi
  if [[ $recovery_only == false && $candidate_value != "$request_value" ]]; then
    die "conflicting TUN requests during active launch"
  fi
  request_values+=("$candidate_value")
done
if [[ $recovery_only == false ]]; then
  expected_staged_config="/var/run/ssrvpn-tun-launch-$app_pid/config.yaml"
  [[ $staged_config == "$expected_staged_config" && -f $staged_config && \
      ! -L $staged_config && $(/usr/bin/stat -f '%u' "$staged_config") == 0 ]] || \
    die "invalid staged Mihomo config"
  config_path=$staged_config
  [[ $request_format == v2 && $request_phase == active && \
      $request_app_pid == "$app_pid" && \
      $request_value == "$expected_request_value" ]] || \
    die "TUN request does not match the requesting app"
fi

script_dir=$(
  CDPATH=''
  cd -- "$(/usr/bin/dirname -- "$0")" && /bin/pwd -P
)
core_gzip="$script_dir/AtlasCore.gz"
core_manifest="$script_dir/AtlasCore-source.txt"
if [[ $recovery_only == false ]]; then
  [[ -f $core_gzip && ! -L $core_gzip && -f $core_manifest && \
      ! -L $core_manifest ]] || die "bundled Mihomo core is missing"
fi

runtime_dir="/var/run/ssrvpn-tun-$user_id"
lock_dir="/var/run/ssrvpn-tun.lock"
lock_owner_path="$lock_dir/runner-pid"
lock_acquired=false
runtime_created=false
child_pid=
validator_pid=
remove_status_on_exit=false
dns_service=
dns_device=
dns_original_mode=
dns_state_dir="/Library/Application Support/SSRVPN"
dns_state_path="$dns_state_dir/tun-dns-state-v1"
dns_state_temp="$dns_state_path.tmp"
dns_original_servers=()
dns_original_server_count=0
tun_dns_server=114.114.114.114
legacy_tun_dns_server=127.0.0.1

is_dns_server() {
  [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || \
     $1 =~ ^[0-9A-Fa-f:.]+(%[A-Za-z0-9._-]+)?$ ]]
}

is_owned_tun_dns_value() {
  [[ $1 == "$tun_dns_server" || $1 == "$legacy_tun_dns_server" ]]
}

active_network_device() {
  local device
  device=$(/sbin/route -n get default 2>/dev/null | \
    /usr/bin/awk '/^[[:space:]]*interface:/{print $2; exit}')
  [[ $device =~ ^[A-Za-z0-9._-]+$ && $device != utun* ]] || return 1
  /usr/bin/printf '%s\n' "$device"
}

# Once Mihomo installs its default route, `route get default` points at utun.
# `scutil --nwi` still lists the effective physical path after the transient
# tunnel interfaces. The first reachable IPv4 interface that is not utun is
# therefore the service whose DNS must remain under this transaction.
active_physical_network_device() {
  local device
  device=$(/usr/sbin/scutil --nwi 2>/dev/null | /usr/bin/awk '
    /^IPv4 network interface information/ { in_ipv4 = 1; next }
    /^IPv6 network interface information/ { exit }
    in_ipv4 && $2 == ":" && $3 == "flags" && \
      $1 ~ /^[A-Za-z0-9._-]+$/ && $1 !~ /^utun/ {
      print $1
      exit
    }
  ') || return 1
  [[ $device =~ ^[A-Za-z0-9._-]+$ && $device != utun* ]] || return 1
  /usr/bin/printf '%s\n' "$device"
}

active_physical_network_unchanged() {
  local current_device
  [[ -n ${dns_device:-} ]] || return 1
  current_device=$(active_physical_network_device) || return 1
  [[ $current_device == "$dns_device" ]]
}

network_service_for_device() {
  local device=$1 service
  [[ $device =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  service=$(/usr/sbin/networksetup -listnetworkserviceorder | \
    /usr/bin/awk -v device="$device" '
      /^\([0-9]+\) / { service = substr($0, index($0, ") ") + 2); next }
      index($0, "Device: " device ")") > 0 { print service; exit }
    ')
  [[ -n $service && ${#service} -le 255 && $service != *$'\n'* && \
      $service != *$'\r'* && $service != *$'\t'* && $service != \** ]] || \
    return 1
  /usr/bin/printf '%s\n' "$service"
}

read_dns_servers() {
  /usr/sbin/networksetup -getdnsservers "$1" 2>/dev/null
}

is_secure_root_directory() {
  local path=$1 owner mode permissions
  [[ -d $path && ! -L $path ]] || return 1
  owner=$(/usr/bin/stat -f '%u' "$path") || return 1
  mode=$(/usr/bin/stat -f '%Lp' "$path") || return 1
  [[ $owner == 0 && $mode =~ ^[0-7]{3,4}$ ]] || return 1
  permissions=$((8#$mode))
  (( (permissions & 022) == 0 ))
}

ensure_dns_state_directory() {
  is_secure_root_directory /Library || return 1
  is_secure_root_directory "/Library/Application Support" || return 1
  if [[ -e $dns_state_dir || -L $dns_state_dir ]]; then
    is_secure_root_directory "$dns_state_dir" || return 1
  else
    /bin/mkdir -m 700 "$dns_state_dir" || return 1
  fi
  /bin/chmod 700 "$dns_state_dir" || return 1
  [[ $(/usr/bin/stat -f '%Lp' "$dns_state_dir") == 700 ]] || return 1
  is_secure_root_directory "$dns_state_dir"
}

is_safe_dns_state_file() {
  local path=$1 owner mode size
  [[ -f $path && ! -L $path ]] || return 1
  owner=$(/usr/bin/stat -f '%u' "$path") || return 1
  mode=$(/usr/bin/stat -f '%Lp' "$path") || return 1
  size=$(/usr/bin/stat -f '%z' "$path") || return 1
  [[ $owner == 0 && $mode == 600 && $size =~ ^[0-9]+$ && \
      $size -le 4096 ]]
}

remove_safe_dns_file() {
  local path=$1
  if [[ ! -e $path && ! -L $path ]]; then
    return 0
  fi
  is_safe_dns_state_file "$path" || return 1
  /bin/rm -f "$path"
  [[ ! -e $path && ! -L $path ]]
}

remove_dns_state() {
  remove_safe_dns_file "$dns_state_path"
}

load_persisted_tun_dns() {
  local line line_number=0
  is_safe_dns_state_file "$dns_state_path" || return 1
  dns_service=
  dns_device=
  dns_original_mode=
  dns_original_servers=()
  dns_original_server_count=0
  while IFS= read -r line || [[ -n $line ]]; do
    ((line_number += 1))
    case $line_number in
      1)
        [[ $line == "schema=1" ]] || return 1
        ;;
      2)
        [[ $line == service=* ]] || return 1
        dns_service=${line#service=}
        [[ -n $dns_service && ${#dns_service} -le 255 && \
            $dns_service != *$'\r'* && $dns_service != *$'\t'* && \
            $dns_service != \** ]] || return 1
        ;;
      3)
        [[ $line == device=* ]] || return 1
        dns_device=${line#device=}
        [[ $dns_device =~ ^[A-Za-z0-9._-]+$ && \
            $dns_device != utun* ]] || return 1
        ;;
      4)
        [[ $line == mode=automatic || $line == mode=manual ]] || return 1
        dns_original_mode=${line#mode=}
        ;;
      *)
        [[ $line == server=* ]] || return 1
        line=${line#server=}
        is_dns_server "$line" || return 1
        dns_original_servers+=("$line")
        ((dns_original_server_count += 1))
        ;;
    esac
  done < "$dns_state_path"
  ((line_number >= 4)) || return 1
  if [[ $dns_original_mode == automatic ]]; then
    ((dns_original_server_count == 0)) || return 1
  else
    ((dns_original_server_count > 0)) || return 1
  fi
}

write_dns_state() {
  ensure_dns_state_directory || return 1
  [[ ! -e $dns_state_path && ! -L $dns_state_path ]] || return 1
  remove_safe_dns_file "$dns_state_temp" || return 1
  (set -o noclobber; : > "$dns_state_temp") 2>/dev/null || return 1
  /bin/chmod 600 "$dns_state_temp" || return 1
  {
    /usr/bin/printf 'schema=1\nservice=%s\ndevice=%s\nmode=%s\n' \
      "$dns_service" "$dns_device" "$dns_original_mode"
    if ((dns_original_server_count > 0)); then
      local server
      for server in "${dns_original_servers[@]}"; do
        /usr/bin/printf 'server=%s\n' "$server"
      done
    fi
  } > "$dns_state_temp"
  is_safe_dns_state_file "$dns_state_temp" || return 1
  /bin/mv "$dns_state_temp" "$dns_state_path" || return 1
  is_safe_dns_state_file "$dns_state_path"
}

dns_snapshot_matches() {
  local current expected
  current=$(read_dns_servers "$dns_service") || return 1
  if [[ $dns_original_mode == automatic ]]; then
    [[ $current == "There aren't any DNS Servers set on "* ]]
    return
  fi
  ((dns_original_server_count > 0)) || return 1
  expected=$(/usr/bin/printf '%s\n' "${dns_original_servers[@]}")
  [[ $current == "$expected" ]]
}

capture_tun_dns_state() {
  local output line
  [[ ! -e $dns_state_path && ! -L $dns_state_path ]] || return 1
  dns_device=$(active_network_device) || return 1
  dns_service=$(network_service_for_device "$dns_device") || return 1
  output=$(read_dns_servers "$dns_service") || return 1
  dns_original_mode=
  dns_original_servers=()
  dns_original_server_count=0
  if [[ $output == "There aren't any DNS Servers set on "* ]]; then
    dns_original_mode=automatic
  else
    dns_original_mode=manual
    while IFS= read -r line; do
      [[ -n $line ]] || continue
      is_dns_server "$line" || return 1
      dns_original_servers+=("$line")
      ((dns_original_server_count += 1))
    done <<< "$output"
    ((dns_original_server_count > 0)) || return 1
  fi
  write_dns_state
}

configure_tun_dns() {
  local mapped_service
  load_persisted_tun_dns || return 1
  active_physical_network_unchanged || return 1
  mapped_service=$(network_service_for_device "$dns_device") || return 1
  [[ $mapped_service == "$dns_service" ]] || return 1
  dns_snapshot_matches || return 1
  /usr/sbin/networksetup -setdnsservers "$dns_service" "$tun_dns_server" \
    >/dev/null 2>&1 || return 1
  [[ $(read_dns_servers "$dns_service") == "$tun_dns_server" ]] || return 1
  /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
}

tun_dns_ownership_healthy() {
  local mapped_service current
  load_persisted_tun_dns || return 1
  active_physical_network_unchanged || return 1
  mapped_service=$(network_service_for_device "$dns_device") || return 1
  [[ $mapped_service == "$dns_service" ]] || return 1
  current=$(read_dns_servers "$dns_service") || return 1
  [[ $current == "$tun_dns_server" ]]
}

check_runtime_tun_dns_health() {
  if ! active_physical_network_unchanged; then
    write_status "error:network-change"
    return 1
  fi
  if ! tun_dns_ownership_healthy; then
    write_status "error:dns"
    return 1
  fi
}

restore_persisted_tun_dns() {
  local current restored
  if [[ ! -e $dns_state_path && ! -L $dns_state_path ]]; then
    return 0
  fi
  ensure_dns_state_directory || return 1
  load_persisted_tun_dns || return 1
  current=$(read_dns_servers "$dns_service") || return 1
  if ! is_owned_tun_dns_value "$current"; then
    echo "SSRVPN TUN: DNS ownership changed; preserving current settings" >&2
    remove_dns_state || return 1
    return 0
  fi

  if [[ $dns_original_mode == automatic ]]; then
    /usr/sbin/networksetup -setdnsservers "$dns_service" empty \
      >/dev/null 2>&1 || return 1
    restored=$(read_dns_servers "$dns_service") || return 1
    [[ $restored == "There aren't any DNS Servers set on "* ]] || return 1
  elif [[ $dns_original_mode == manual && $dns_original_server_count -gt 0 ]]; then
    /usr/sbin/networksetup -setdnsservers "$dns_service" \
      "${dns_original_servers[@]}" >/dev/null 2>&1 || return 1
    restored=$(read_dns_servers "$dns_service") || return 1
    [[ $restored == $(/usr/bin/printf '%s\n' "${dns_original_servers[@]}") ]] || \
      return 1
  else
    return 1
  fi
  remove_dns_state || return 1
  /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
}

restore_persisted_tun_dns_with_retry() {
  for _ in {1..5}; do
    restore_persisted_tun_dns && return 0
    /bin/sleep 0.2
  done
  return 1
}

is_safe_lock_directory() {
  [[ -d $lock_dir && ! -L $lock_dir && \
      $(/usr/bin/stat -f '%u' "$lock_dir") == 0 && \
      $(/usr/bin/stat -f '%Lp' "$lock_dir") == 700 ]]
}

read_lock_owner() {
  local owner mode value
  is_safe_lock_directory || return 1
  [[ -f $lock_owner_path && ! -L $lock_owner_path ]] || return 1
  owner=$(/usr/bin/stat -f '%u' "$lock_owner_path") || return 1
  mode=$(/usr/bin/stat -f '%Lp' "$lock_owner_path") || return 1
  value=$(/usr/bin/tr -d '[:space:]' < "$lock_owner_path") || return 1
  [[ $owner == 0 && $mode == 600 && $value =~ ^[0-9]+$ && $value -gt 1 ]] || \
    return 1
  /usr/bin/printf '%s\n' "$value"
}

acquire_tun_lock() {
  local prior_owner stale_lock
  if ! /bin/mkdir -m 700 "$lock_dir" 2>/dev/null; then
    prior_owner=$(read_lock_owner) || return 1
    if /bin/kill -0 "$prior_owner" 2>/dev/null; then
      return 1
    fi
    stale_lock="$lock_dir.stale-$$"
    [[ ! -e $stale_lock && ! -L $stale_lock ]] || return 1
    /bin/mv "$lock_dir" "$stale_lock" || return 1
    if ! /bin/mkdir -m 700 "$lock_dir"; then
      # If no contender won the path, restore the original lock atomically.
      # Otherwise preserve both the contender and quarantined owner evidence.
      if [[ ! -e $lock_dir && ! -L $lock_dir ]]; then
        /bin/mv "$stale_lock" "$lock_dir" || true
      fi
      return 1
    fi
    lock_acquired=true
    /bin/rm -rf "$stale_lock" || return 1
  else
    lock_acquired=true
  fi
  (set -o noclobber; : > "$lock_owner_path") 2>/dev/null || return 1
  /bin/chmod 600 "$lock_owner_path" || return 1
  /usr/bin/printf '%s\n' "$$" > "$lock_owner_path"
  [[ $(read_lock_owner) == "$$" ]]
}

read_safe_user_request() {
  local path=$1 owner size value
  [[ -f $path && ! -L $path ]] || return 1
  owner=$(/usr/bin/stat -f '%u' "$path") || return 1
  size=$(/usr/bin/stat -f '%z' "$path") || return 1
  value=$(/bin/cat "$path") || return 1
  [[ $owner == "$user_id" && $size =~ ^[0-9]+$ && $size -le 64 && \
      $size -eq $((${#value} + 1)) ]] || return 1
  /usr/bin/printf '%s' "$value"
}

request_matches_runner_generation() {
  local value=$1
  if [[ $request_format == legacy ]]; then
    [[ $value == "$request_value" ]]
    return
  fi
  [[ $value =~ ^v2:(active|recovery):([0-9]+):([0-9a-f]{32})$ && \
      ${BASH_REMATCH[2]} == "$request_app_pid" && \
      ${BASH_REMATCH[3]} == "$request_nonce" ]]
}

active_request_matches() {
  local value
  [[ $request_format == v2 && $request_phase == active ]] || return 1
  value=$(read_safe_user_request "$request_path") || return 1
  [[ $value == "$request_value" ]]
}

retire_owned_tun_request_at() {
  local path=$1 expected_value=$2 value retired_path marker_still_owned
  [[ -n ${path:-} && -n ${request_value:-} && -n ${user_id:-} ]] || \
    return 0
  if [[ ! -e $path && ! -L $path ]]; then
    return 0
  fi
  value=$(read_safe_user_request "$path") || return 1
  # A newly launched app may already own this path. Only the exact generation
  # accepted by this runner may be retired.
  if [[ $recovery_only == true ]]; then
    [[ $value == "$expected_value" ]] || return 0
  else
    request_matches_runner_generation "$value" || return 0
  fi
  retired_path="$path.retired-$$"
  [[ ! -e $retired_path && ! -L $retired_path ]] || return 1
  /bin/mv "$path" "$retired_path" || return 1
  value=
  value=$(read_safe_user_request "$retired_path") || value=
  if [[ $recovery_only == true ]]; then
    marker_still_owned=false
    [[ $value == "$expected_value" ]] && marker_still_owned=true
  else
    marker_still_owned=false
    request_matches_runner_generation "$value" && marker_still_owned=true
  fi
  if [[ $marker_still_owned == true ]]; then
    /bin/rm -f "$retired_path"
    return
  fi
  # The path changed between validation and quarantine. Restore it only via an
  # atomic no-clobber hard link; if a newer marker already exists, preserve
  # both entries for diagnosis instead of overwriting that generation.
  echo "SSRVPN TUN: request marker changed during cleanup; preserving it" >&2
  if [[ -f $retired_path && ! -L $retired_path && \
        ! -e $path && ! -L $path ]] && \
      /bin/ln "$retired_path" "$path" 2>/dev/null; then
    /bin/rm -f "$retired_path"
  fi
  return 1
}

retire_owned_tun_requests() {
  local index path failed=false
  for index in "${!request_paths[@]}"; do
    path=${request_paths[$index]}
    if ! retire_owned_tun_request_at "$path" "${request_values[$index]}"; then
      failed=true
    fi
  done
  [[ $failed == false ]]
}

cleanup() {
  local cleanup_failed=false
  local dns_restored=true
  local dns_recovery_was_delayed=false
  # Every resource below belongs to the global TUN transaction. A contender
  # that never acquired the lock must not retire another runner's marker,
  # signal its core, remove its runtime, or mutate its DNS journal.
  if [[ $lock_acquired != true ]]; then
    return 0
  fi
  if [[ $lock_acquired == true ]] && \
      ! restore_persisted_tun_dns_with_retry; then
    write_status "error:dns-recovery" || true
    remove_status_on_exit=false
    echo "SSRVPN TUN: failed to restore DNS settings" >&2
    dns_restored=false
    dns_recovery_was_delayed=true
  fi
  # Keep the privileged runner as a recovery supervisor until the original DNS
  # is restored or ownership moves away. The legacy loopback value remains
  # recognized so an interrupted v3.4.8 session cannot strand system DNS.
  while [[ $dns_restored == false ]]; do
    if restore_persisted_tun_dns_with_retry; then
      dns_restored=true
      remove_status_on_exit=true
      break
    fi
    /bin/sleep 1
  done
  if ! retire_owned_tun_requests; then
    write_status "error:marker" || true
    remove_status_on_exit=false
    cleanup_failed=true
  fi
  if [[ $dns_recovery_was_delayed == true ]]; then
    echo "SSRVPN TUN: DNS settings recovered; continuing safe teardown" >&2
  fi
  if [[ -n ${validator_pid:-} ]] && /bin/kill -0 "$validator_pid" 2>/dev/null; then
    /bin/kill -TERM "$validator_pid" 2>/dev/null || true
    /bin/sleep 0.2
    /bin/kill -KILL "$validator_pid" 2>/dev/null || true
    wait "$validator_pid" 2>/dev/null || true
  fi
  if [[ -n ${child_pid:-} ]] && /bin/kill -0 "$child_pid" 2>/dev/null; then
    /bin/kill -TERM "$child_pid" 2>/dev/null || true
    for _ in {1..24}; do
      /bin/kill -0 "$child_pid" 2>/dev/null || break
      /bin/sleep 0.5
    done
    /bin/kill -KILL "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  fi
  if [[ $runtime_created == true ]]; then
    /bin/rm -rf "$runtime_dir"
    runtime_created=false
  fi
  if [[ $lock_acquired == true ]]; then
    remove_safe_dns_file "$dns_state_temp" || true
    /bin/rm -f "$lock_owner_path"
    /bin/rmdir "$lock_dir" 2>/dev/null || true
    lock_acquired=false
  fi
  if [[ $remove_status_on_exit == true ]]; then
    /bin/rm -f "$status_path"
  fi
  [[ $cleanup_failed == false ]]
}

on_exit() {
  local exit_code=$?
  # Once teardown begins, repeated terminal signals must not interrupt the
  # DNS-before-core ordering. SIGKILL remains the unavoidable system boundary.
  trap '' INT TERM HUP
  trap - EXIT
  cleanup || exit_code=1
  exit "$exit_code"
}

trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
acquire_tun_lock || die "another TUN session is already active or needs a restart"

ensure_dns_state_directory || {
  write_status "error:dns"
  exit 1
}
if ! restore_persisted_tun_dns_with_retry; then
  write_status "error:dns"
  exit 1
fi
if [[ $recovery_only == true ]]; then
  remove_status_on_exit=true
  exit 0
fi

if [[ -e $runtime_dir || -L $runtime_dir ]]; then
  write_status "error:stale"
  exit 1
fi
/bin/mkdir -m 700 "$runtime_dir"
runtime_created=true
runtime_core="$runtime_dir/AtlasCore"
runtime_config="$runtime_dir/config.yaml"
/usr/bin/gzip -cd "$core_gzip" > "$runtime_core"
expected=$(/usr/bin/sed -n 's/^Executable SHA256: \([0-9a-f]\{64\}\)$/\1/p' "$core_manifest")
actual=$(/usr/bin/shasum -a 256 "$runtime_core" | /usr/bin/awk '{print $1}')
[[ -n $expected && $actual == "$expected" ]] || die "Mihomo core digest mismatch"
/bin/chmod 700 "$runtime_core"
/bin/cp -p "$config_path" "$runtime_config"
/bin/chmod 600 "$runtime_config"
if [[ -f "$data_dir/geoip.metadb" && ! -L "$data_dir/geoip.metadb" ]]; then
  /bin/cp -p "$data_dir/geoip.metadb" "$runtime_dir/geoip.metadb"
  /bin/chmod 600 "$runtime_dir/geoip.metadb"
fi
/bin/mkdir -m 700 "$runtime_dir/providers" "$runtime_dir/tmp"
for provider_name in ssrvpn-geosite-cn.mrs ssrvpn-geoip-cn.mrs; do
  provider_source="$data_dir/providers/$provider_name"
  if [[ -f $provider_source && ! -L $provider_source && \
        $(/usr/bin/stat -f '%u' "$provider_source") == "$user_id" ]]; then
    /bin/cp -p "$provider_source" "$runtime_dir/providers/$provider_name"
    /bin/chmod 600 "$runtime_dir/providers/$provider_name"
  fi
done

TMPDIR="$runtime_dir/tmp" "$runtime_core" -t -d "$runtime_dir" \
  -f "$runtime_config" > "$runtime_dir/config-test.log" 2>&1 &
validator_pid=$!
validation_timed_out=true
for _ in {1..120}; do
  if ! /bin/kill -0 "$validator_pid" 2>/dev/null; then
    validation_timed_out=false
    break
  fi
  if ! active_request_matches || ! /bin/kill -0 "$app_pid" 2>/dev/null; then
    remove_status_on_exit=true
    exit 0
  fi
  /bin/sleep 0.25
done
if [[ $validation_timed_out == true ]]; then
  /bin/kill -TERM "$validator_pid" 2>/dev/null || true
  /bin/sleep 0.2
  /bin/kill -KILL "$validator_pid" 2>/dev/null || true
  wait "$validator_pid" 2>/dev/null || true
  validator_pid=
  write_status "error:timeout"
  exit 1
fi
if ! wait "$validator_pid"; then
  validator_pid=
  write_status "error:core"
  exit 1
fi
validator_pid=

# Capture the physical network service and its exact DNS snapshot before
# Mihomo installs the TUN default route. The later mutation must use only this
# captured service and must fail closed if the user changes networks meanwhile.
if ! capture_tun_dns_state; then
  write_status "error:dns"
  exit 1
fi

TMPDIR="$runtime_dir/tmp" "$runtime_core" -d "$runtime_dir" -f "$runtime_config" \
  > "$runtime_dir/mihomo.log" 2>&1 &
child_pid=$!

report_core_failure() {
  if /usr/bin/grep -Eiq 'permission denied|operation not permitted' \
      "$runtime_dir/mihomo.log"; then
    write_status "error:permission"
  elif /usr/bin/grep -Eiq 'address already in use|bind.*failed' \
      "$runtime_dir/mihomo.log"; then
    write_status "error:port"
  elif /usr/bin/grep -Eiq 'tun|route|interface' "$runtime_dir/mihomo.log"; then
    write_status "error:tun"
  else
    write_status "error:core"
  fi
}

for _ in {1..10}; do
  if ! /bin/kill -0 "$child_pid" 2>/dev/null; then
    report_core_failure
    exit 1
  fi
  if ! active_request_matches || ! /bin/kill -0 "$app_pid" 2>/dev/null; then
    remove_status_on_exit=true
    exit 0
  fi
  /bin/sleep 0.2
done
if ! active_physical_network_unchanged; then
  write_status "error:network-change"
  exit 1
fi
if ! configure_tun_dns; then
  write_status "error:dns"
  exit 1
fi
write_status "running"

health_tick=0
while active_request_matches && /bin/kill -0 "$app_pid" 2>/dev/null; do
  if ! /bin/kill -0 "$child_pid" 2>/dev/null; then
    report_core_failure
    exit 1
  fi
  ((health_tick += 1))
  if ((health_tick % 4 == 0)) && ! check_runtime_tun_dns_health; then
    exit 1
  fi
  /bin/sleep 0.5
done
remove_status_on_exit=true
