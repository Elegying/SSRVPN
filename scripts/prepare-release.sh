#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

tag=${1:?Usage: prepare-release.sh <new-release-tag>}
repo=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}
run_id=${GITHUB_RUN_ID:?GITHUB_RUN_ID is required}
run_attempt=${GITHUB_RUN_ATTEMPT:-1}
output_file=${GITHUB_OUTPUT:-}
summary_file=${GITHUB_STEP_SUMMARY:-}
branch=""
branch_pushed=false
pr_number=""
merged=false
protection_policy=".github/main-branch-protection.json"
branch_protection_read_token="${BRANCH_PROTECTION_READ_TOKEN:-}"
unset BRANCH_PROTECTION_READ_TOKEN

fail() {
  echo "::error::$*" >&2
  exit 1
}

required_check_count="$(python3 - "$protection_policy" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    policy = json.load(handle)
checks = policy.get("required_status_checks", {}).get("checks", [])
if not isinstance(checks, list) or not checks:
    raise SystemExit("main branch protection policy has no required checks")
print(len(checks))
PY
)"

verify_main_branch_protection() {
  if [ -z "$branch_protection_read_token" ]; then
    fail "BRANCH_PROTECTION_READ_TOKEN is required to verify main protection"
  fi
  GH_TOKEN="$branch_protection_read_token" gh api \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "repos/$repo/branches/main/protection" |
    python3 scripts/verify_main_branch_protection.py \
      --expected "$protection_policy"
}

write_output() {
  local name=$1
  local value=$2
  if [ -n "$output_file" ]; then
    printf '%s=%s\n' "$name" "$value" >> "$output_file"
  fi
}

append_summary() {
  if [ -n "$summary_file" ]; then
    printf '%s\n' "$1" >> "$summary_file"
  fi
}

cleanup_failed_branch() {
  local status=$?
  trap - EXIT
  if [ "$status" -ne 0 ] && [ "$branch_pushed" = true ] && \
    [ -z "$pr_number" ] && [ "$merged" = false ]; then
    git push origin --delete "$branch" >/dev/null 2>&1 || \
      echo "::warning::Could not delete failed preparation branch $branch" >&2
  fi
  exit "$status"
}
trap cleanup_failed_branch EXIT

# GitHub documents that workflow_dispatch always creates a run when invoked
# with GITHUB_TOKEN. The current REST response includes the exact run ID/URL.
# https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow
# https://docs.github.com/en/rest/actions/workflows#create-a-workflow-dispatch-event
dispatch_workflow() {
  local workflow=$1
  local ref=$2
  local response

  response="$(gh api --method POST \
    -H "X-GitHub-Api-Version: 2026-03-10" \
    "repos/$repo/actions/workflows/$workflow/dispatches" \
    -f "ref=$ref")"
  python3 - "$workflow" "$response" <<'PY'
import json
import sys

workflow = sys.argv[1]
try:
    payload = json.loads(sys.argv[2])
except json.JSONDecodeError as error:
    raise SystemExit(f"{workflow} dispatch returned invalid JSON: {error}")
run_id = payload.get("workflow_run_id")
run_url = payload.get("html_url")
if isinstance(run_id, bool) or not isinstance(run_id, int) or run_id <= 0:
    raise SystemExit(f"{workflow} dispatch returned no valid workflow_run_id")
if not isinstance(run_url, str) or not run_url.startswith("https://github.com/"):
    raise SystemExit(f"{workflow} dispatch returned no valid html_url")
print(f"{run_id}\t{run_url}")
PY
}

wait_for_workflow() {
  local watched_run_id=$1
  gh run watch "$watched_run_id" --exit-status --interval 20
}

require_current_main_sha() {
  local expected_sha=$1
  local context=$2
  local actual_sha=""

  git fetch --no-tags origin main:refs/remotes/origin/main ||
    fail "Could not refresh origin/main while verifying the release commit"
  actual_sha="$(git rev-parse --verify 'origin/main^{commit}')" ||
    fail "Could not resolve origin/main while verifying the release commit"
  if [ "$actual_sha" != "$expected_sha" ]; then
    fail "$context"
  fi
}

read_exact_main_ci_state() {
  local inspected_run_id=$1
  local expected_sha=$2

  gh api \
    -H "X-GitHub-Api-Version: 2026-03-10" \
    "repos/$repo/actions/runs/$inspected_run_id" |
    jq -er \
      --arg repo "$repo" \
      --arg sha "$expected_sha" \
      --argjson run_id "$inspected_run_id" '
        (.path | split("@")[0]) as $workflow_path |
        .status as $status |
        if .id != $run_id or
          .head_branch != "main" or
          .head_sha != $sha or
          $workflow_path != ".github/workflows/ci.yml" or
          (.event != "push" and .event != "workflow_dispatch") or
          .html_url != ("https://github.com/" + $repo + "/actions/runs/" + ($run_id | tostring)) or
          .repository.full_name != $repo or
          .head_repository.full_name != $repo
        then error("workflow run identity does not match the frozen main commit")
        elif ($status | type) != "string" or
          (["queued", "in_progress", "requested", "waiting", "pending", "completed"] | index($status)) == null
        then error("workflow run has an unsupported status")
        elif .conclusion != null and (.conclusion | type) != "string"
        then error("workflow run has an invalid conclusion")
        elif $status == "completed" and .conclusion == null
        then error("completed workflow run has no conclusion")
        elif $status != "completed" and .conclusion != null
        then error("active workflow run unexpectedly has a conclusion")
        else [$status, (.conclusion // "")] | @tsv
        end
      '
}

wait_for_pull_request_checks() {
  local pull_request=$1
  local checks_url=$2
  local check_count=""
  local warned=false

  # Pull-request workflows created by GITHUB_TOKEN can remain in
  # action_required until a maintainer approves them. Keep the release
  # transaction open long enough for that approval instead of failing after
  # one minute. We still require the repository's protected checks and never
  # bypass branch protection.
  for _ in {1..90}; do
    check_count="$(gh pr checks "$pull_request" \
      --required --json name --jq 'length' 2>/dev/null || true)"
    if [ "$check_count" = "$required_check_count" ]; then
      gh pr checks "$pull_request" \
        --required --watch --fail-fast --interval 20
      return
    fi
    if [[ "$check_count" =~ ^[0-9]+$ ]] && \
      [ "$check_count" -gt "$required_check_count" ]; then
      fail "Pull request $pull_request registered unexpected required checks"
    fi
    if [ "$warned" = false ]; then
      echo "::warning::Approve the pending GitHub Actions workflow for pull request $pull_request, then this release will continue automatically: $checks_url" >&2
      warned=true
    fi
    sleep 20
  done
  fail "Required checks were not approved and registered for pull request $pull_request within 30 minutes: $checks_url"
}

require_tag_absent() {
  local tag_status=0
  local release_error
  release_error="$(mktemp)"

  git ls-remote --exit-code --tags origin "refs/tags/$tag" \
    >/dev/null 2>&1 || tag_status=$?
  if [ "$tag_status" -eq 0 ]; then
    rm -f "$release_error"
    fail "Release tag already exists: $tag"
  fi
  if [ "$tag_status" -ne 2 ]; then
    rm -f "$release_error"
    fail "Could not determine whether release tag $tag exists"
  fi

  if gh api "repos/$repo/releases/tags/$tag" >/dev/null 2>"$release_error"; then
    rm -f "$release_error"
    fail "GitHub Release already exists: $tag"
  fi
  if ! grep -Fq "HTTP 404" "$release_error"; then
    sed 's/^/GitHub API: /' "$release_error" >&2
    rm -f "$release_error"
    fail "Could not determine whether GitHub Release $tag exists"
  fi
  rm -f "$release_error"
}

if [[ ! "$tag" =~ ^v[0-9]+(\.[0-9]+){1,3}$ ]]; then
  fail "Invalid release tag: $tag"
fi
if [[ ! "$run_id" =~ ^[1-9][0-9]*$ ]] || \
  [[ ! "$run_attempt" =~ ^[1-9][0-9]*$ ]]; then
  fail "GitHub run identity is invalid"
fi

git fetch --no-tags origin main:refs/remotes/origin/main
git fetch --tags origin
source_sha="$(git rev-parse --verify 'HEAD^{commit}')"
main_sha="$(git rev-parse --verify 'origin/main^{commit}')"
if [ "$source_sha" != "$main_sha" ]; then
  fail "Prepare Release must start from the current main tip"
fi
verify_main_branch_protection

bash scripts/check-version-sync.sh
app_version="$(awk -F"'" '/appVersion = / { print $2; exit }' \
  packages/ssrvpn_shared/lib/constants/app_constants.dart)"
if [ "${tag#v}" != "$app_version" ]; then
  fail "Release tag $tag does not match app version $app_version"
fi

current_full="$(awk '/^version:/ { print $2; exit }' SSRVPN_Android/pubspec.yaml)"
current_code=${current_full##*+}
previous_tag="$(git tag --list 'v*' --sort=-v:refname |
  grep -E '^v[0-9]+(\.[0-9]+){1,3}$' |
  grep -vx "$tag" | head -1 || true)"
if [ -n "$previous_tag" ]; then
  previous_full="$(git show "$previous_tag:SSRVPN_Android/pubspec.yaml" |
    awk '/^version:/ { print $2; exit }')"
  previous_code=${previous_full##*+}
  python3 scripts/verify-release-transition.py \
    --target "${tag#v}" \
    --current-version "${previous_tag#v}" \
    --target-build-code "$current_code" \
    --current-build-code "$previous_code"
fi

require_tag_absent

bash scripts/bootstrap-core-assets.sh
python3 scripts/sync-geoip-metadb.py
python3 scripts/ensure-geoip-mirror.py --upload
bash scripts/verify-core-assets.sh

unexpected="$(git diff --name-only -- . ':!docs/GEOIP_SOURCE.txt')"
if [ -n "$unexpected" ]; then
  printf 'Unexpected tracked files changed:\n%s\n' "$unexpected" >&2
  exit 1
fi
untracked="$(git ls-files --others --exclude-standard)"
if [ -n "$untracked" ]; then
  printf 'Unexpected untracked files created:\n%s\n' "$untracked" >&2
  exit 1
fi

geoip_changed=false
branch_ci_url=""
pr_url=""
if ! git diff --quiet -- docs/GEOIP_SOURCE.txt; then
  geoip_changed=true
  branch="automation/release-${tag#v}-geoip-${run_id}-${run_attempt}"
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git switch -c "$branch"
  git add -- docs/GEOIP_SOURCE.txt
  git commit -m "chore(assets): refresh GeoIP for $tag"
  branch_sha="$(git rev-parse --verify 'HEAD^{commit}')"
  git push origin "HEAD:refs/heads/$branch"
  branch_pushed=true

  pr_url="$(gh pr create \
    --base main \
    --head "$branch" \
    --title "chore(assets): refresh GeoIP for $tag" \
    --body "Automated pre-release GeoIP refresh for $tag. The exact upstream source, deterministic gzip digest, and immutable SSRVPN mirror are pinned before the release tag is created.")"
  pr_number=${pr_url##*/}
  if [[ ! "$pr_number" =~ ^[1-9][0-9]*$ ]]; then
    fail "Could not determine the GeoIP pull request number"
  fi
  # GitHub holds pull-request workflows created by GITHUB_TOKEN for maintainer
  # approval. A separately dispatched branch run does not attach its checks to
  # the pull request, so wait for the protected PR checks themselves.
  branch_ci_url="$pr_url/checks"
  wait_for_pull_request_checks "$pr_number" "$branch_ci_url"

  git fetch --no-tags origin main:refs/remotes/origin/main
  if [ "$(git rev-parse --verify 'origin/main^{commit}')" != "$main_sha" ]; then
    fail "main advanced while the GeoIP pull request was verified; retry safely"
  fi

  gh pr merge "$pr_number" --rebase --delete-branch
  merged=true

  merge_state="$(gh pr view "$pr_number" --json state --jq .state)"
  main_sha="$(gh pr view "$pr_number" --json mergeCommit --jq .mergeCommit.oid)"
  if [ "$merge_state" != MERGED ] || \
    [[ ! "$main_sha" =~ ^[0-9a-f]{40}$ ]]; then
    fail "GeoIP pull request did not produce a valid merged commit"
  fi

  git fetch --no-tags origin main:refs/remotes/origin/main
  if [ "$(git rev-parse --verify 'origin/main^{commit}')" != "$main_sha" ]; then
    fail "Merged GeoIP commit is not the current main tip"
  fi
  if [ "$(git rev-parse "$branch_sha^{tree}")" != \
    "$(git rev-parse "$main_sha^{tree}")" ]; then
    fail "Merged GeoIP tree differs from the verified branch tree"
  fi
fi

main_ci_reused=false
main_ci_waited=false
main_ci_dispatched=false
main_ci_wait_attempts=0
max_main_ci_wait_attempts=3
main_ci_post_wait_misses=0
max_main_ci_post_wait_misses=5
reusable_main_ci=""
read_main_ci_identity() {
  if [[ "$reusable_main_ci" == *$'\n'* ]]; then
    fail "Reusable exact-main CI returned more than one result"
  fi
  IFS=$'\t' read -r main_ci_run_id main_ci_url <<<"$reusable_main_ci"
  if [[ ! "$main_ci_run_id" =~ ^[1-9][0-9]*$ ]] ||
    [ "$main_ci_url" != \
      "https://github.com/$repo/actions/runs/$main_ci_run_id" ]; then
    fail "Reusable exact-main CI returned an invalid run identity"
  fi
}

wait_for_exact_main_ci() {
  local watched_run_id=$1
  local watch_status=0
  local run_state=""
  local status=""
  local conclusion=""

  main_ci_wait_attempts=$((main_ci_wait_attempts + 1))
  if [ "$main_ci_wait_attempts" -gt "$max_main_ci_wait_attempts" ]; then
    fail "Exact-main CI was replaced too many times; retry release preparation safely"
  fi
  wait_for_workflow "$watched_run_id" || watch_status=$?
  if [ "$watch_status" -eq 0 ]; then
    return 0
  fi

  require_current_main_sha \
    "$main_sha" \
    "main advanced while exact-main CI was running; retry safely"
  run_state="$(read_exact_main_ci_state "$watched_run_id" "$main_sha")" ||
    fail "Could not verify failed exact-main CI run $watched_run_id"
  if [[ "$run_state" == *$'\n'* ]]; then
    fail "Exact-main CI state returned more than one result"
  fi
  IFS=$'\t' read -r status conclusion <<<"$run_state"
  if [ "$status" = completed ] && [ "$conclusion" = cancelled ]; then
    echo "::warning::Exact-main CI run $watched_run_id was replaced; looking for a same-commit successor" >&2
    return 75
  fi
  fail "Exact-main CI run $watched_run_id did not succeed (status=$status, conclusion=${conclusion:-none})"
}

while true; do
  reuse_status=0
  reusable_main_ci="$(python3 scripts/find-reusable-main-ci.py \
    --repo "$repo" \
    --sha "$main_sha" \
    --policy "$protection_policy" \
    --max-age-hours 24)" || reuse_status=$?
  case "$reuse_status" in
    0)
      read_main_ci_identity
      if [ "$main_ci_dispatched" = false ]; then
        main_ci_reused=true
      fi
      echo "Reusing verified exact-main CI run: $main_ci_url"
      break
      ;;
    3)
      if [ "$main_ci_waited" = true ]; then
        require_current_main_sha \
          "$main_sha" \
          "main advanced while exact-main CI results were propagating; retry safely"
        main_ci_post_wait_misses=$((main_ci_post_wait_misses + 1))
        if [ "$main_ci_post_wait_misses" -gt "$max_main_ci_post_wait_misses" ]; then
          fail "Waited exact-main CI did not pass strict post-completion verification"
        fi
        echo "::warning::Exact-main CI is not yet reusable; retrying strict verification ($main_ci_post_wait_misses/$max_main_ci_post_wait_misses)" >&2
        sleep 2
        continue
      fi
      require_current_main_sha \
        "$main_sha" \
        "main advanced before exact-main CI dispatch; retry safely"
      IFS=$'\t' read -r main_ci_run_id main_ci_url \
        < <(dispatch_workflow "ci.yml" main)
      dispatched_state="$(read_exact_main_ci_state "$main_ci_run_id" "$main_sha")" ||
        fail "Dispatched exact-main CI does not target the frozen main commit"
      if [[ "$dispatched_state" == *$'\n'* ]]; then
        fail "Dispatched exact-main CI state returned more than one result"
      fi
      main_ci_dispatched=true
      main_ci_waited=true
      wait_status=0
      wait_for_exact_main_ci "$main_ci_run_id" || wait_status=$?
      if [ "$wait_status" -ne 0 ] && [ "$wait_status" -ne 75 ]; then
        fail "Could not safely wait for dispatched exact-main CI"
      fi
      continue
      ;;
    4)
      read_main_ci_identity
      main_ci_waited=true
      main_ci_post_wait_misses=0
      echo "Waiting for existing exact-main CI run: $main_ci_url"
      wait_status=0
      wait_for_exact_main_ci "$main_ci_run_id" || wait_status=$?
      if [ "$wait_status" -ne 0 ] && [ "$wait_status" -ne 75 ]; then
        fail "Could not safely wait for existing exact-main CI"
      fi
      continue
      ;;
    *)
      fail "Could not safely determine whether exact-main CI is reusable"
      ;;
  esac
done

git fetch --no-tags origin main:refs/remotes/origin/main
if [ "$(git rev-parse --verify 'origin/main^{commit}')" != "$main_sha" ]; then
  fail "main advanced after verification; refusing to create $tag"
fi

# Exact-main CI can run long enough for upstream latest to roll. Recheck the
# reviewed pointer before crossing the immutable tag boundary; release.yml keeps
# the same read-only gate as defense in depth.
python3 scripts/sync-geoip-metadb.py --check
require_tag_absent
verify_main_branch_protection

git fetch --no-tags origin main:refs/remotes/origin/main
if [ "$(git rev-parse --verify 'origin/main^{commit}')" != "$main_sha" ]; then
  fail "main advanced before tag creation; retry safely"
fi

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git tag -a "$tag" "$main_sha" -m "Release ${tag#v}"
git push origin "refs/tags/$tag"

IFS=$'\t' read -r release_run_id release_run_url \
  < <(dispatch_workflow "release.yml" "$tag")
write_output geoip_changed "$geoip_changed"
write_output main_ci_reused "$main_ci_reused"
write_output branch_ci_url "$branch_ci_url"
write_output geoip_pr_url "$pr_url"
write_output main_ci_url "$main_ci_url"
write_output release_run_url "$release_run_url"

append_summary "## Release preparation for $tag"
append_summary "- GeoIP changed: $geoip_changed"
if [ -n "$pr_url" ]; then
  append_summary "- GeoIP pull request: $pr_url"
  append_summary "- Protected PR checks: $branch_ci_url"
fi
if [ "$main_ci_dispatched" = true ]; then
  append_summary "- Exact-main CI: $main_ci_url (this preparation triggered CI; this exact-main run passed final required-job verification)"
elif [ "$main_ci_waited" = true ]; then
  append_summary "- Exact-main CI: $main_ci_url (this preparation waited for active CI; this exact-main run passed final required-job verification)"
elif [ "$main_ci_reused" = true ]; then
  append_summary "- Exact-main CI: $main_ci_url (reused after exact job verification)"
fi
append_summary "- Release workflow: $release_run_url"

wait_for_workflow "$release_run_id"
