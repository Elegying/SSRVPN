#!/usr/bin/env bash
# The extracted production functions consume globals that ShellCheck cannot see.
# shellcheck disable=SC2034
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/SSRVPN_MacOS/assets/macos_tun_runner.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ssrvpn-tun-dns-test.XXXXXX")"
LIBRARY="$TEST_ROOT/runner-functions.sh"

cleanup_test_root() {
  rm -rf "$TEST_ROOT"
}
trap cleanup_test_root EXIT INT TERM HUP

# Exercise the production function bodies without executing the privileged
# runner entrypoint. These functions are intentionally contiguous in the real
# runner; failing to extract them is a test failure, not a silent test skip.
awk '
  /^is_dns_server\(\) \{/ { capture = 1 }
  /^trap on_exit EXIT/ { exit }
  capture { print }
' "$RUNNER" > "$LIBRARY"

for required in \
  'capture_tun_dns_state()' \
  'restore_persisted_tun_dns()' \
  'tun_dns_ownership_healthy()' \
  'acquire_tun_lock()' \
  'cleanup()'; do
  grep -Fq "$required" "$LIBRARY" || {
    echo "macOS TUN DNS behavior test failed: could not extract $required" >&2
    exit 1
  }
done

# shellcheck source=/dev/null
source "$LIBRARY"

tun_dns_server=114.114.114.114
legacy_tun_dns_server=127.0.0.1

write_status() {
  MOCK_STATUS_HISTORY="${MOCK_STATUS_HISTORY}${MOCK_STATUS_HISTORY:+,}$1"
  printf '%s\n' "$1" > "$status_path"
}

AUTOMATIC_DNS="There aren't any DNS Servers set on Wi-Fi."
MOCK_DNS_CURRENT=
MOCK_DNS_SET_FAILURE=false
MOCK_DNS_SET_FAILURES_REMAINING=0
MOCK_DNS_GET_FAILURE=false
MOCK_DNS_SET_CALLS=0
MOCK_LAST_DNS_SET=
MOCK_UNSAFE_PATH=
MOCK_UNSAFE_OWNER=0
MOCK_UNSAFE_MODE=600
MOCK_LOCK_MKDIR_CALLS=0
MOCK_LOCK_SECOND_BEHAVIOR=normal
MOCK_COMPETITOR_PID=424242
MOCK_NETWORK_SERVICE=Wi-Fi
MOCK_ACTIVE_NETWORK_DEVICE=en0
MOCK_SCUTIL_CALLS=0
MOCK_CHILD_PID=31337
MOCK_CHILD_ALIVE=false
MOCK_CHILD_KILL_CALLS=0
MOCK_CHILD_KILLED_BEFORE_DNS_RESTORE=false
MOCK_STATUS_HISTORY=

# Absolute command names in the production runner are deliberately retained.
# Bash functions with the same names inject deterministic platform boundaries
# while file type and journal contents still use real temporary files.
/sbin/route() {
  printf '   route to: default\ninterface: en0\n'
}

/usr/sbin/scutil() {
  [[ ${1:-} == --nwi ]] || return 1
  MOCK_SCUTIL_CALLS=$((MOCK_SCUTIL_CALLS + 1))
  printf '%s\n' \
    'Network information' \
    '' \
    'IPv4 network interface information' \
    '   utun9 : flags      : 0x7 (IPv4,IPv6,DNS)' \
    '           address    : 198.18.0.1' \
    '           reach      : 0x00000003 (Reachable,Transient Connection)' \
    "     $MOCK_ACTIVE_NETWORK_DEVICE : flags      : 0x5 (IPv4,DNS)" \
    '           address    : 192.168.100.185' \
    '           reach      : 0x00000002 (Reachable)' \
    'IPv6 network interface information'
}

/usr/sbin/networksetup() {
  local operation=${1:-}
  shift || true
  case "$operation" in
    -listnetworkserviceorder)
      printf '(1) %s\n(Hardware Port: Wi-Fi, Device: en0)\n' \
        "$MOCK_NETWORK_SERVICE"
      ;;
    -getdnsservers)
      [[ $MOCK_DNS_GET_FAILURE == false ]] || return 1
      printf '%s\n' "$MOCK_DNS_CURRENT"
      ;;
    -setdnsservers)
      MOCK_DNS_SET_CALLS=$((MOCK_DNS_SET_CALLS + 1))
      if [[ $MOCK_DNS_SET_FAILURE == true || \
            $MOCK_DNS_SET_FAILURES_REMAINING -gt 0 ]]; then
        if ((MOCK_DNS_SET_FAILURES_REMAINING > 0)); then
          MOCK_DNS_SET_FAILURES_REMAINING=$((MOCK_DNS_SET_FAILURES_REMAINING - 1))
        fi
        return 1
      fi
      local service=${1:-}
      shift || true
      [[ $service == Wi-Fi && $# -gt 0 ]] || return 1
      if [[ $1 == empty && $# -eq 1 ]]; then
        MOCK_DNS_CURRENT=$AUTOMATIC_DNS
        MOCK_LAST_DNS_SET=empty
      else
        MOCK_DNS_CURRENT=$(printf '%s\n' "$@")
        MOCK_LAST_DNS_SET=$MOCK_DNS_CURRENT
      fi
      ;;
    *)
      return 1
      ;;
  esac
}

/usr/bin/dscacheutil() {
  return 0
}

/usr/bin/stat() {
  [[ ${1:-} == -f && $# -eq 3 ]] || return 1
  local format=$2 path=$3
  case "$format" in
    %u)
      if [[ -n $MOCK_UNSAFE_PATH && $path == "$MOCK_UNSAFE_PATH" ]]; then
        printf '%s\n' "$MOCK_UNSAFE_OWNER"
      else
        printf '0\n'
      fi
      ;;
    %Lp)
      if [[ -n $MOCK_UNSAFE_PATH && $path == "$MOCK_UNSAFE_PATH" ]]; then
        printf '%s\n' "$MOCK_UNSAFE_MODE"
      elif [[ -d $path ]]; then
        printf '700\n'
      else
        printf '600\n'
      fi
      ;;
    %z)
      [[ -f $path ]] || return 1
      command wc -c < "$path" | tr -d '[:space:]'
      printf '\n'
      ;;
    *)
      return 1
      ;;
  esac
}

/bin/kill() {
  if [[ ${1:-} == -0 ]]; then
    if [[ ${2:-} == "$MOCK_CHILD_PID" && $MOCK_CHILD_ALIVE == true ]]; then
      return 0
    fi
    # Existing fixture owners are stale. A concurrently-created owner is live.
    [[ ${2:-} == "$MOCK_COMPETITOR_PID" ]]
    return
  fi
  if [[ ${2:-} == "$MOCK_CHILD_PID" ]]; then
    MOCK_CHILD_KILL_CALLS=$((MOCK_CHILD_KILL_CALLS + 1))
    if [[ $MOCK_DNS_CURRENT == "$tun_dns_server" ]]; then
      MOCK_CHILD_KILLED_BEFORE_DNS_RESTORE=true
    fi
    MOCK_CHILD_ALIVE=false
  fi
  return 0
}

/bin/sleep() {
  return 0
}

/bin/mkdir() {
  local path='' argument
  for argument in "$@"; do
    path=$argument
  done
  if [[ $path == "$lock_dir" ]]; then
    MOCK_LOCK_MKDIR_CALLS=$((MOCK_LOCK_MKDIR_CALLS + 1))
    if [[ $MOCK_LOCK_MKDIR_CALLS -eq 2 ]]; then
      case "$MOCK_LOCK_SECOND_BEHAVIOR" in
        fail-empty)
          return 1
          ;;
        race)
          command /bin/mkdir -m 700 "$lock_dir"
          printf '%s\n' "$MOCK_COMPETITOR_PID" > "$lock_owner_path"
          command /bin/chmod 600 "$lock_owner_path"
          return 1
          ;;
      esac
    fi
  fi
  command /bin/mkdir "$@"
}

# Directory safety itself is covered by the privilege guard. Behavior tests
# redirect the persistent journal to a temporary directory on every platform.
is_secure_root_directory() {
  return 0
}

setup_case() {
  local name=$1
  CASE_ROOT="$TEST_ROOT/$name"
  mkdir -p "$CASE_ROOT/state"
  dns_state_dir="$CASE_ROOT/state"
  dns_state_path="$dns_state_dir/tun-dns-state-v1"
  dns_state_temp="$dns_state_path.tmp"
  dns_service=
  dns_device=
  dns_original_mode=
  dns_original_servers=()
  dns_original_server_count=0
  MOCK_DNS_CURRENT=
  MOCK_DNS_SET_FAILURE=false
  MOCK_DNS_SET_FAILURES_REMAINING=0
  MOCK_DNS_GET_FAILURE=false
  MOCK_DNS_SET_CALLS=0
  MOCK_LAST_DNS_SET=
  MOCK_UNSAFE_PATH=
  MOCK_UNSAFE_OWNER=0
  MOCK_UNSAFE_MODE=600
  lock_dir="$CASE_ROOT/tun.lock"
  lock_owner_path="$lock_dir/runner-pid"
  lock_acquired=false
  MOCK_LOCK_MKDIR_CALLS=0
  MOCK_LOCK_SECOND_BEHAVIOR=normal
  MOCK_NETWORK_SERVICE=Wi-Fi
  MOCK_ACTIVE_NETWORK_DEVICE=en0
  MOCK_SCUTIL_CALLS=0
  runtime_health_failure_count=0
  runtime_health_failure_status=
  runtime_health_failure_limit=3
  MOCK_CHILD_ALIVE=false
  MOCK_CHILD_KILL_CALLS=0
  MOCK_CHILD_KILLED_BEFORE_DNS_RESTORE=false
  MOCK_STATUS_HISTORY=
  runtime_dir="$CASE_ROOT/runtime"
  runtime_created=false
  child_pid=
  validator_pid=
  remove_status_on_exit=false
  status_path="$CASE_ROOT/status"
  request_path="$CASE_ROOT/.tun-session-request"
  request_format=v2
  request_phase=active
  request_app_pid=777
  request_nonce=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  request_value=v2:active:777:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  request_paths=("$request_path")
  request_values=("$request_value")
  recovery_only=false
  user_id=0
}

write_journal() {
  local mode=$1
  shift
  {
    printf 'schema=1\nservice=Wi-Fi\ndevice=en0\nmode=%s\n' "$mode"
    local server
    for server in "$@"; do
      printf 'server=%s\n' "$server"
    done
  } > "$dns_state_path"
  chmod 600 "$dns_state_path"
}

write_stale_lock() {
  mkdir -m 700 "$lock_dir"
  printf '77777\n' > "$lock_owner_path"
  chmod 600 "$lock_owner_path"
}

assert_equal() {
  local expected=$1 actual=$2 message=$3
  if [[ $actual != "$expected" ]]; then
    printf 'assertion failed: %s\nexpected: <%s>\nactual:   <%s>\n' \
      "$message" "$expected" "$actual" >&2
    return 1
  fi
}

assert_file_absent() {
  local path=$1 message=$2
  if [[ -e $path || -L $path ]]; then
    echo "assertion failed: $message ($path still exists)" >&2
    return 1
  fi
}

test_automatic_dns_capture_and_restore() {
  setup_case automatic
  MOCK_DNS_CURRENT=$AUTOMATIC_DNS

  capture_tun_dns_state || return 1
  assert_equal Wi-Fi "$dns_service" 'capture must bind the physical service' || return 1
  assert_equal en0 "$dns_device" 'capture must bind the physical device' || return 1
  grep -Fxq 'mode=automatic' "$dns_state_path" || return 1
  if grep -Fq 'server=' "$dns_state_path"; then
    echo 'assertion failed: automatic DNS journal must not contain servers' >&2
    return 1
  fi

  MOCK_DNS_CURRENT=$tun_dns_server
  restore_persisted_tun_dns || return 1
  assert_equal "$AUTOMATIC_DNS" "$MOCK_DNS_CURRENT" \
    'automatic DNS must be restored exactly' || return 1
  assert_file_absent "$dns_state_path" \
    'successful automatic restoration must retire the journal' || return 1
}

test_tun_dns_uses_routable_hijack_target() {
  setup_case routable-target
  MOCK_DNS_CURRENT=$AUTOMATIC_DNS

  capture_tun_dns_state || return 1
  configure_tun_dns || return 1

  assert_equal "$tun_dns_server" "$MOCK_DNS_CURRENT" \
    'TUN must publish a routable DNS target for system resolvers' || return 1
  assert_equal "$tun_dns_server" "$MOCK_LAST_DNS_SET" \
    'networksetup must receive the managed DNS target' || return 1
  tun_dns_ownership_healthy || return 1
}

test_legacy_loopback_dns_is_recovered() {
  setup_case legacy-loopback
  write_journal automatic
  MOCK_DNS_CURRENT=$legacy_tun_dns_server

  restore_persisted_tun_dns || return 1

  assert_equal "$AUTOMATIC_DNS" "$MOCK_DNS_CURRENT" \
    'an interrupted v3.4.8 loopback DNS transaction must be restored' || return 1
  assert_file_absent "$dns_state_path" \
    'legacy DNS recovery must retire its journal' || return 1
}

test_manual_multi_dns_restores_exact_order() {
  setup_case manual
  local original
  original=$'1.1.1.1\n2606:4700:4700::1111\n8.8.8.8'
  MOCK_DNS_CURRENT=$original

  capture_tun_dns_state || return 1
  MOCK_DNS_CURRENT=$tun_dns_server
  restore_persisted_tun_dns || return 1

  assert_equal "$original" "$MOCK_DNS_CURRENT" \
    'manual DNS servers must be restored in exact order' || return 1
  assert_equal "$original" "$MOCK_LAST_DNS_SET" \
    'networksetup must receive every captured DNS server' || return 1
  assert_file_absent "$dns_state_path" \
    'successful manual restoration must retire the journal' || return 1
}

test_user_dns_change_is_preserved_and_retires_journal() {
  setup_case user-change
  write_journal manual 1.1.1.1 8.8.8.8
  MOCK_DNS_CURRENT=9.9.9.9

  restore_persisted_tun_dns || return 1

  assert_equal 9.9.9.9 "$MOCK_DNS_CURRENT" \
    'a user DNS change must not be overwritten' || return 1
  assert_equal 0 "$MOCK_DNS_SET_CALLS" \
    'ownership loss must not call the DNS setter' || return 1
  assert_file_absent "$dns_state_path" \
    'ownership loss must retire the stale journal' || return 1
}

test_restore_failure_keeps_journal() {
  setup_case restore-failure
  write_journal manual 1.1.1.1 8.8.8.8
  MOCK_DNS_CURRENT=$tun_dns_server
  MOCK_DNS_SET_FAILURE=true

  if restore_persisted_tun_dns; then
    echo 'assertion failed: an injected DNS setter failure must fail closed' >&2
    return 1
  fi

  [[ -f $dns_state_path ]] || return 1
  assert_equal "$tun_dns_server" "$MOCK_DNS_CURRENT" \
    'failed restoration must leave the owned DNS value unchanged' || return 1
}

test_cleanup_failure_is_observable() {
  setup_case cleanup-failure
  write_journal manual 1.1.1.1 8.8.8.8
  MOCK_DNS_CURRENT=$tun_dns_server
  MOCK_DNS_SET_FAILURES_REMAINING=6
  lock_acquired=true

  cleanup || return 1

  [[ $MOCK_STATUS_HISTORY == *error:dns-recovery* ]] || {
    echo 'assertion failed: cleanup must publish the transient DNS restoration failure' >&2
    return 1
  }
  assert_equal $'1.1.1.1\n8.8.8.8' "$MOCK_DNS_CURRENT" \
    'cleanup recovery supervisor must keep retrying without a live child' || return 1
  assert_file_absent "$dns_state_path" \
    'eventual cleanup recovery must retire the journal' || return 1
}

test_cleanup_keeps_dns_core_until_restore_recovers() {
  setup_case cleanup-transient-failure
  write_journal manual 1.1.1.1 8.8.8.8
  MOCK_DNS_CURRENT=$tun_dns_server
  # Exhaust the bounded first pass. The recovery supervisor must keep the
  # managed DNS transaction intact before it tears the core down.
  MOCK_DNS_SET_FAILURES_REMAINING=5
  lock_acquired=true
  child_pid=$MOCK_CHILD_PID
  MOCK_CHILD_ALIVE=true
  mkdir -p "$runtime_dir"
  runtime_created=true

  cleanup || return 1

  assert_equal false "$MOCK_CHILD_KILLED_BEFORE_DNS_RESTORE" \
    'cleanup must not terminate the core before managed DNS is restored' || return 1
  ((MOCK_CHILD_KILL_CALLS > 0)) || {
    echo 'assertion failed: core must be terminated after DNS recovery' >&2
    return 1
  }
  assert_equal $'1.1.1.1\n8.8.8.8' "$MOCK_DNS_CURRENT" \
    'cleanup must eventually restore the original DNS before teardown' || return 1
  assert_file_absent "$dns_state_path" \
    'successful supervised recovery must retire the DNS journal' || return 1
}

test_successful_cleanup_retires_only_its_request_generation() {
  setup_case cleanup-request
  lock_acquired=true
  printf '%s\n' "$request_value" > "$request_path"
  chmod 600 "$request_path"

  cleanup || return 1

  assert_file_absent "$request_path" \
    'verified cleanup must retire its own recovery marker' || return 1

  setup_case cleanup-newer-request
  lock_acquired=true
  printf 'v2:active:777:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' > "$request_path"
  chmod 600 "$request_path"

  cleanup || return 1

  [[ -f $request_path ]] || return 1
  assert_equal v2:active:777:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    "$(tr -d '[:space:]' < "$request_path")" \
    'cleanup must preserve a marker from a newer app generation' || return 1
}

test_recovery_phase_stops_and_retires_the_same_generation() {
  setup_case cleanup-recovery-phase
  lock_acquired=true
  printf '%s\n' "$request_value" > "$request_path"
  chmod 600 "$request_path"
  active_request_matches || return 1

  printf 'v2:recovery:777:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$request_path"
  if active_request_matches; then
    echo 'assertion failed: recovery phase must stop the active runner loop' >&2
    return 1
  fi

  cleanup || return 1
  assert_file_absent "$request_path" \
    'cleanup must retire the same nonce in recovery phase' || return 1
}

test_recovery_only_retires_conflicting_legacy_generations() {
  setup_case cleanup-recovery-conflict
  lock_acquired=true
  recovery_only=true
  local second_path="$CASE_ROOT/legacy/.tun-session-request"
  mkdir -p "$(dirname "$second_path")"
  printf '777\n' > "$request_path"
  printf 'v2:recovery:888:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' > "$second_path"
  chmod 600 "$request_path" "$second_path"
  request_paths=("$request_path" "$second_path")
  request_values=(
    '777'
    'v2:recovery:888:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  )
  request_format=legacy
  request_value=777
  request_app_pid=777
  request_nonce=

  cleanup || return 1

  assert_file_absent "$request_path" \
    'recovery-only cleanup must retire the first captured generation' || return 1
  assert_file_absent "$second_path" \
    'recovery-only cleanup must retire the second captured generation' || return 1
}

test_recovery_only_lock_rejection_preserves_recovery_owner() {
  setup_case recovery-lock-rejected
  recovery_only=true
  request_phase=recovery
  request_value=v2:recovery:777:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  request_values=("$request_value")
  printf '%s\n' "$request_value" > "$request_path"
  chmod 600 "$request_path"
  write_journal manual 1.1.1.1 8.8.8.8
  MOCK_DNS_CURRENT=$tun_dns_server

  # A live privileged runner owns the global transaction. This recovery-only
  # contender must fail to acquire the lock and must not retire or tear down
  # any state that only the lock owner can prove safe.
  mkdir -m 700 "$lock_dir"
  printf '%s\n' "$MOCK_COMPETITOR_PID" > "$lock_owner_path"
  chmod 600 "$lock_owner_path"
  if acquire_tun_lock; then
    echo 'assertion failed: live lock owner must reject recovery-only acquisition' >&2
    return 1
  fi
  assert_equal false "$lock_acquired" \
    'rejected recovery-only runner must remain outside the global transaction' || return 1

  child_pid=$MOCK_CHILD_PID
  MOCK_CHILD_ALIVE=true
  mkdir -p "$runtime_dir"
  runtime_created=true

  cleanup || true

  local failed=false
  if [[ ! -f $request_path ]]; then
    echo 'assertion failed: runner without the lock must preserve the recovery marker' >&2
    failed=true
  fi
  if [[ ! -f $dns_state_path ]]; then
    echo 'assertion failed: runner without the lock must preserve the DNS journal' >&2
    failed=true
  fi
  if [[ $MOCK_DNS_SET_CALLS -ne 0 || $MOCK_DNS_CURRENT != "$tun_dns_server" ]]; then
    echo 'assertion failed: runner without the lock must not mutate DNS' >&2
    failed=true
  fi
  if [[ $MOCK_CHILD_KILL_CALLS -ne 0 || $MOCK_CHILD_ALIVE != true ]]; then
    echo 'assertion failed: runner without the lock must not signal the DNS core' >&2
    failed=true
  fi
  if [[ ! -d $runtime_dir || $runtime_created != true ]]; then
    echo 'assertion failed: runner without the lock must not remove core runtime state' >&2
    failed=true
  fi
  [[ $failed == false ]]
}

test_runtime_dns_ownership_checks_service_and_value() {
  setup_case runtime-ownership
  write_journal automatic
  MOCK_DNS_CURRENT=$tun_dns_server
  tun_dns_ownership_healthy || return 1

  MOCK_DNS_CURRENT=9.9.9.9
  if tun_dns_ownership_healthy; then
    echo 'assertion failed: changed DNS must fail runtime ownership health' >&2
    return 1
  fi

  MOCK_DNS_CURRENT=$tun_dns_server
  MOCK_NETWORK_SERVICE=Renamed
  if tun_dns_ownership_healthy; then
    echo 'assertion failed: remapped service must fail runtime ownership health' >&2
    return 1
  fi
}

test_runtime_health_debounces_transient_dns_probe_failures() {
  setup_case runtime-health-debounce
  write_journal automatic
  MOCK_DNS_CURRENT=$tun_dns_server
  printf 'running\n' > "$status_path"
  load_persisted_tun_dns || return 1

  check_runtime_tun_dns_health || {
    echo 'assertion failed: healthy runtime probe must succeed' >&2
    return 1
  }

  MOCK_DNS_GET_FAILURE=true
  check_runtime_tun_dns_health || {
    echo 'assertion failed: first transient DNS probe failure must be tolerated' >&2
    return 1
  }
  check_runtime_tun_dns_health || {
    echo 'assertion failed: second transient DNS probe failure must be tolerated' >&2
    return 1
  }
  assert_equal running "$(tr -d '[:space:]' < "$status_path")" \
    'transient probe failures must not publish a terminal status' || return 1

  MOCK_DNS_GET_FAILURE=false
  check_runtime_tun_dns_health || {
    echo 'assertion failed: a successful probe must reset the failure streak' >&2
    return 1
  }
  MOCK_DNS_GET_FAILURE=true
  check_runtime_tun_dns_health || return 1
  check_runtime_tun_dns_health || return 1
  if check_runtime_tun_dns_health; then
    echo 'assertion failed: three consecutive DNS probe failures must stop the runner' >&2
    return 1
  fi
  assert_equal error:dns "$(tr -d '[:space:]' < "$status_path")" \
    'terminal DNS failure must remain observable to the app' || return 1
}

test_runtime_dns_ownership_fails_when_active_physical_device_changes() {
  setup_case runtime-network-change
  write_journal automatic
  MOCK_DNS_CURRENT=$tun_dns_server
  tun_dns_ownership_healthy || return 1

  MOCK_ACTIVE_NETWORK_DEVICE=en1
  if tun_dns_ownership_healthy; then
    echo 'assertion failed: switching the active physical interface must fail DNS ownership health' >&2
    return 1
  fi
  check_runtime_tun_dns_health || return 1
  check_runtime_tun_dns_health || return 1
  if check_runtime_tun_dns_health; then
    echo 'assertion failed: a persistent network change must fail the runner health gate' >&2
    return 1
  fi
  assert_equal error:network-change "$(tr -d '[:space:]' < "$status_path")" \
    'runtime network change must tell the app to reconnect' || return 1
}

test_recovery_only_entrypoint_validates_marker_and_journal() {
  grep -Fq -- '--recover-dns' "$RUNNER" || return 1
  grep -Fq 'unsafe TUN request path' "$RUNNER" || return 1
  grep -Fq 'load_persisted_tun_dns || return 1' "$RUNNER" || return 1
  grep -Fq 'restore_persisted_tun_dns_with_retry' "$RUNNER" || return 1
  grep -Fq 'v2:(active|recovery)' "$RUNNER" || return 1
  grep -Fq -- '--request-token' "$RUNNER" || return 1
}

test_malformed_journal_fails_closed() {
  setup_case malformed
  printf 'schema=2\nservice=Wi-Fi\n' > "$dns_state_path"
  chmod 600 "$dns_state_path"
  MOCK_DNS_CURRENT=$tun_dns_server

  if restore_persisted_tun_dns; then
    echo 'assertion failed: malformed journal must fail closed' >&2
    return 1
  fi

  [[ -f $dns_state_path ]] || return 1
  assert_equal 0 "$MOCK_DNS_SET_CALLS" \
    'malformed journal must not mutate DNS' || return 1
}

test_symlink_journal_fails_closed() {
  setup_case symlink
  local target="$CASE_ROOT/attacker-state"
  printf 'schema=1\nservice=Wi-Fi\ndevice=en0\nmode=automatic\n' > "$target"
  ln -s "$target" "$dns_state_path"
  MOCK_DNS_CURRENT=$tun_dns_server

  if restore_persisted_tun_dns; then
    echo 'assertion failed: symlink journal must fail closed' >&2
    return 1
  fi

  [[ -L $dns_state_path ]] || return 1
  assert_equal 0 "$MOCK_DNS_SET_CALLS" 'symlink journal must not mutate DNS' || return 1
}

test_wrong_permission_journal_fails_closed() {
  setup_case wrong-mode
  write_journal automatic
  MOCK_UNSAFE_PATH=$dns_state_path
  MOCK_UNSAFE_MODE=644
  MOCK_DNS_CURRENT=$tun_dns_server

  if restore_persisted_tun_dns; then
    echo 'assertion failed: group/world-readable journal must fail closed' >&2
    return 1
  fi

  [[ -f $dns_state_path ]] || return 1
  assert_equal 0 "$MOCK_DNS_SET_CALLS" \
    'unsafe journal permissions must not mutate DNS' || return 1
}

test_stale_lock_is_recovered() {
  setup_case stale-success
  write_stale_lock

  acquire_tun_lock || return 1

  [[ $lock_acquired == true ]] || return 1
  assert_equal "$$" "$(tr -d '[:space:]' < "$lock_owner_path")" \
    'recovered lock must publish the current runner PID' || return 1
  assert_file_absent "$lock_dir.stale-$$" \
    'successful stale recovery must remove the quarantine directory' || return 1
}

test_stale_lock_creation_failure_restores_original_lock() {
  setup_case stale-create-failure
  write_stale_lock
  MOCK_LOCK_SECOND_BEHAVIOR=fail-empty

  if acquire_tun_lock; then
    echo 'assertion failed: injected replacement lock failure must fail closed' >&2
    return 1
  fi

  [[ -d $lock_dir && -f $lock_owner_path ]] || return 1
  assert_equal 77777 "$(tr -d '[:space:]' < "$lock_owner_path")" \
    'failed replacement must restore the original stale lock evidence' || return 1
  assert_file_absent "$lock_dir.stale-$$" \
    'restored stale lock must not leave a detached quarantine directory' || return 1
}

test_stale_lock_creation_race_preserves_both_owners() {
  setup_case stale-race
  write_stale_lock
  MOCK_LOCK_SECOND_BEHAVIOR=race

  if acquire_tun_lock; then
    echo 'assertion failed: replacement lock race must fail closed' >&2
    return 1
  fi

  [[ -d $lock_dir && -f $lock_owner_path ]] || return 1
  assert_equal "$MOCK_COMPETITOR_PID" \
    "$(tr -d '[:space:]' < "$lock_owner_path")" \
    'replacement race must preserve the competitor lock' || return 1
  [[ -d $lock_dir.stale-$$ && -f $lock_dir.stale-$$/runner-pid ]] || return 1
  assert_equal 77777 \
    "$(tr -d '[:space:]' < "$lock_dir.stale-$$/runner-pid")" \
    'replacement race must not destroy the quarantined owner evidence' || return 1
}

failures=0
tests=0
for entry in \
  'automatic DNS capture and restore:test_automatic_dns_capture_and_restore' \
  'routable DNS hijack target:test_tun_dns_uses_routable_hijack_target' \
  'legacy loopback DNS recovery:test_legacy_loopback_dns_is_recovered' \
  'manual multi-DNS exact restore:test_manual_multi_dns_restores_exact_order' \
  'user DNS change preservation:test_user_dns_change_is_preserved_and_retires_journal' \
  'restore failure journal retention:test_restore_failure_keeps_journal' \
  'cleanup failure propagation:test_cleanup_failure_is_observable' \
  'cleanup keeps DNS core until recovery:test_cleanup_keeps_dns_core_until_restore_recovers' \
  'cleanup request generation safety:test_successful_cleanup_retires_only_its_request_generation' \
  'active to recovery phase handoff:test_recovery_phase_stops_and_retires_the_same_generation' \
  'recovery-only conflicting generations:test_recovery_only_retires_conflicting_legacy_generations' \
  'recovery-only live lock preservation:test_recovery_only_lock_rejection_preserves_recovery_owner' \
  'runtime DNS ownership:test_runtime_dns_ownership_checks_service_and_value' \
  'runtime health debounce:test_runtime_health_debounces_transient_dns_probe_failures' \
  'runtime physical network change:test_runtime_dns_ownership_fails_when_active_physical_device_changes' \
  'recovery-only ownership validation:test_recovery_only_entrypoint_validates_marker_and_journal' \
  'malformed journal fail-closed:test_malformed_journal_fails_closed' \
  'symlink journal fail-closed:test_symlink_journal_fails_closed' \
  'wrong permission journal fail-closed:test_wrong_permission_journal_fails_closed' \
  'stale lock recovery:test_stale_lock_is_recovered' \
  'stale lock creation failure recovery:test_stale_lock_creation_failure_restores_original_lock' \
  'stale lock creation race:test_stale_lock_creation_race_preserves_both_owners'; do
  name=${entry%%:*}
  function_name=${entry#*:}
  tests=$((tests + 1))
  if ("$function_name"); then
    printf 'ok %d - %s\n' "$tests" "$name"
  else
    printf 'not ok %d - %s\n' "$tests" "$name" >&2
    failures=$((failures + 1))
  fi
done

if ((failures > 0)); then
  echo "macOS TUN DNS transaction behavior tests failed: $failures/$tests" >&2
  exit 1
fi

echo "macOS TUN DNS transaction behavior tests passed: $tests/$tests"
