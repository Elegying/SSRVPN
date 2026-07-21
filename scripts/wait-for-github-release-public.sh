#!/usr/bin/env bash
set -euo pipefail

tag=${1:?Usage: wait-for-github-release-public.sh <tag> [attempts] [attempted|not-attempted]}
attempts=${2:-5}
mutation_state=${3:-attempted}

if ! [[ $attempts =~ ^[1-9][0-9]*$ ]]; then
  echo "attempts must be a positive integer" >&2
  exit 64
fi
if [[ $mutation_state != attempted && $mutation_state != not-attempted ]]; then
  echo "mutation state must be attempted or not-attempted" >&2
  exit 64
fi

release_state=""
for ((attempt = 1; attempt <= attempts; attempt++)); do
  if release_state="$(gh release view "$tag" \
    --json isDraft,isPrerelease \
    --jq '[.isDraft, .isPrerelease] | @tsv' 2>/dev/null)"; then
    case "$release_state" in
      $'false\tfalse')
        printf '%s\n' "$release_state"
        exit 0
        ;;
      $'true\tfalse' | $'false\ttrue' | $'true\ttrue') ;;
      *) release_state="" ;;
    esac
  else
    release_state=""
  fi

  if ((attempt < attempts)); then
    sleep "$attempt"
  fi
done

if [[ -n $release_state ]]; then
  printf '%s\n' "$release_state"
  if [[ $mutation_state == not-attempted ]]; then
    exit 1
  fi
  # A successful or failed publication mutation can race an eventually
  # consistent read. Once the mutation was attempted, a non-public read cannot
  # prove that GitHub stayed non-public, so callers must preserve OSS state.
  exit 87
fi

# No trustworthy final read: callers must preserve the OSS backup and require
# explicit state confirmation instead of guessing whether publication won.
exit 87
