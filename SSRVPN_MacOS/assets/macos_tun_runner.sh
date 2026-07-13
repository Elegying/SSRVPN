#!/bin/bash
set -euo pipefail

PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
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
[[ $# -eq 4 && $1 == "--app-pid" && $2 =~ ^[0-9]+$ && $2 -gt 1 && \
   $3 == "--staged-config" ]] || \
  die "invalid arguments"
app_pid=$2
staged_config=$4
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
for candidate in \
  "$user_home/Library/Application Support/SSRVPN" \
  "$user_home/Library/Application Support/com.ssrvpn.ssrvpnClient/SSRVPN"; do
  if [[ -f "$candidate/$request_name" && ! -L "$candidate/$request_name" ]]; then
    data_dir=$candidate
    break
  fi
done
[[ -n $data_dir && -d $data_dir && ! -L $data_dir ]] || die "invalid SSRVPN data directory"
[[ $(/usr/bin/stat -f '%u' "$data_dir") == "$user_id" ]] || die "data directory owner mismatch"

request_path="$data_dir/$request_name"
expected_staged_config="/var/run/ssrvpn-tun-launch-$app_pid/config.yaml"
[[ $staged_config == "$expected_staged_config" && -f $staged_config && \
    ! -L $staged_config && $(/usr/bin/stat -f '%u' "$staged_config") == 0 ]] || \
  die "invalid staged Mihomo config"
config_path=$staged_config
[[ $(/usr/bin/tr -d '[:space:]' < "$request_path") == "$app_pid" ]] || \
  die "TUN request does not match the requesting app"

script_dir=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && /bin/pwd -P)
core_gzip="$script_dir/AtlasCore.gz"
core_manifest="$script_dir/AtlasCore-source.txt"
[[ -f $core_gzip && ! -L $core_gzip && -f $core_manifest && ! -L $core_manifest ]] || \
  die "bundled Mihomo core is missing"

runtime_dir="/var/run/ssrvpn-tun-$user_id"
lock_dir="$runtime_dir.lock"
/bin/mkdir "$lock_dir" 2>/dev/null || die "another TUN session is already active"
child_pid=
validator_pid=
remove_status_on_exit=false
cleanup() {
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
  /bin/rm -rf "$runtime_dir"
  /bin/rmdir "$lock_dir" 2>/dev/null || true
  if [[ $remove_status_on_exit == true ]]; then
    /bin/rm -f "$status_path"
  fi
}
trap cleanup EXIT INT TERM HUP

[[ ! -e $runtime_dir && ! -L $runtime_dir ]] || die "unsafe TUN runtime path"
/bin/mkdir -m 700 "$runtime_dir"
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
  if [[ ! -f $request_path ]] || ! /bin/kill -0 "$app_pid" 2>/dev/null; then
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
  if [[ ! -f $request_path ]] || ! /bin/kill -0 "$app_pid" 2>/dev/null; then
    remove_status_on_exit=true
    exit 0
  fi
  /bin/sleep 0.2
done
write_status "running"

while [[ -f $request_path ]] && /bin/kill -0 "$app_pid" 2>/dev/null; do
  if ! /bin/kill -0 "$child_pid" 2>/dev/null; then
    report_core_failure
    exit 1
  fi
  /bin/sleep 0.5
done
remove_status_on_exit=true
