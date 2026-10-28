#!/usr/bin/env bash
# Sourced by verify-all.sh; changes apply only to this verification process tree.
VERIFICATION_SHIM_DIR=''

cleanup_verification_environment() {
  if [[ -n "$VERIFICATION_SHIM_DIR" ]]; then
    rm -f -- "$VERIFICATION_SHIM_DIR/python3"
    rmdir -- "$VERIFICATION_SHIM_DIR"
  fi
}

prepare_verification_environment() {
  export PYTHONUTF8=1
  export PYTHONIOENCODING=utf-8
  if ! python3 -c 'import sys; assert sys.version_info >= (3, 12)' >/dev/null 2>&1; then
    if ! python -c 'import sys; assert sys.version_info >= (3, 12)' >/dev/null 2>&1; then
      echo "Verification requires Python 3.12 or newer on PATH (python3 or python)." >&2
      return 1
    fi
    SSRVPN_VERIFICATION_PYTHON="$(command -v python)"
    export SSRVPN_VERIFICATION_PYTHON
    VERIFICATION_SHIM_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ssrvpn-python.XXXXXX")" || return 1
    # Expand interpreter and arguments in the child, never embed executable paths as code.
    # shellcheck disable=SC2016
    printf '#!/usr/bin/env bash\nexec "$SSRVPN_VERIFICATION_PYTHON" "$@"\n' > "$VERIFICATION_SHIM_DIR/python3" || return 1
    chmod +x "$VERIFICATION_SHIM_DIR/python3" || return 1
    export PATH="$VERIFICATION_SHIM_DIR:$PATH"
    hash -r
  fi
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*)
      if [[ -z "${JAVA_HOME:-}" ]] && command -v java >/dev/null 2>&1; then
        JAVA_HOME="$(dirname "$(dirname "$(command -v java)")")"
        JAVA_HOME="$(cygpath -m "$JAVA_HOME")"
        export JAVA_HOME
      fi
      if [[ -z "${ANDROID_HOME:-}${ANDROID_SDK_ROOT:-}" && -n "${LOCALAPPDATA:-}" ]]; then
        local sdk="${LOCALAPPDATA//\\//}/Android/Sdk"
        if [[ -d "$sdk" ]]; then
          export ANDROID_HOME="$sdk" ANDROID_SDK_ROOT="$sdk"
        fi
      fi
      ;;
  esac
}

check_verification_prerequisites() {
  local missing=0 tool
  for tool in git curl gzip openssl shellcheck dart; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Verification prerequisite missing: $tool (install it and add it to PATH)." >&2
      missing=1
    fi
  done
  if (( missing != 0 )); then return 1; fi
  openssl version >/dev/null || return 1
  shellcheck --version >/dev/null || return 1
  case "$(uname -s)" in
    MINGW* | MSYS* | CYGWIN*) ;;
    *) echo "Verification prerequisites available."; return 0 ;;
  esac
  if [[ -z "${JAVA_HOME:-}" || ! -x "$JAVA_HOME/bin/java" ]]; then
    echo "Android native verification requires JDK 17; set JAVA_HOME to its directory." >&2
    return 1
  fi
  local java_version
  java_version="$("$JAVA_HOME/bin/java" -version 2>&1)" || return 1
  if [[ ! "$java_version" =~ version\ \"17\. ]]; then
    echo "Android native verification requires JDK 17 at JAVA_HOME." >&2
    return 1
  fi
  local sdk="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
  if [[ -z "$sdk" || ! -d "$sdk" ]]; then
    echo "Android SDK missing; set ANDROID_SDK_ROOT or ANDROID_HOME before full verification." >&2
    return 1
  fi
  echo "Verification prerequisites available."
}
