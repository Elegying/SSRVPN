#!/usr/bin/env python3
"""Find a recent exact-main CI run that is safe to reuse."""

import argparse
import json
import re
import subprocess
import sys
from collections import defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


API_VERSION = "2026-03-10"
EXPECTED_WORKFLOW_PATH = ".github/workflows/ci.yml"
ALLOWED_EVENTS = {"push", "workflow_dispatch"}
SKIPPABLE_REQUIRED_JOB = "Dependency review"
NOT_FOUND_EXIT = 3
WAITABLE_EXIT = 4
# GitHub can hold an Actions run in these pre-completion states while it waits
# for scheduling, concurrency, an environment, or another platform gate.
WAITABLE_STATUSES = {"queued", "in_progress", "requested", "waiting", "pending"}
MAX_PAGE_SIZE = 100
MAX_RESULTS = 1000
MAX_JSON_BYTES = 16 * 1024 * 1024
MAX_FUTURE_CLOCK_SKEW = timedelta(minutes=5)


class VerificationError(RuntimeError):
    pass


def positive_int(value, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise VerificationError(f"{label} must be a positive integer")
    return value


def nonnegative_int(value, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise VerificationError(f"{label} must be a non-negative integer")
    return value


def required_string(value, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise VerificationError(f"{label} must be a non-empty string")
    return value


def parse_timestamp(value, label: str) -> datetime:
    text = required_string(value, label)
    try:
        parsed = datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as error:
        raise VerificationError(f"{label} is not a valid timestamp") from error
    if parsed.tzinfo is None:
        raise VerificationError(f"{label} must include a timezone")
    return parsed.astimezone(timezone.utc)


def gh_api_json(endpoint: str, fields: Iterable[Tuple[str, str]] = ()):  # noqa: ANN201
    command = [
        "gh",
        "api",
        "--method",
        "GET",
        "-H",
        "Accept: application/vnd.github+json",
        "-H",
        f"X-GitHub-Api-Version: {API_VERSION}",
        endpoint,
    ]
    for name, value in fields:
        command.extend(("-f", f"{name}={value}"))

    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError as error:
        raise VerificationError(f"could not execute gh for {endpoint}: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.strip() or f"exit {result.returncode}"
        raise VerificationError(f"GitHub API request failed for {endpoint}: {detail}")
    if len(result.stdout.encode("utf-8")) > MAX_JSON_BYTES:
        raise VerificationError(f"GitHub API response is too large for {endpoint}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise VerificationError(
            f"GitHub API returned invalid JSON for {endpoint}: {error}"
        ) from error


def paginated_items(
    endpoint: str,
    collection_name: str,
    fields: Sequence[Tuple[str, str]],
) -> List[Mapping]:
    expected_total: Optional[int] = None
    values: List[Mapping] = []
    seen_ids = set()

    for page in range(1, (MAX_RESULTS // MAX_PAGE_SIZE) + 1):
        payload = gh_api_json(
            endpoint,
            (*fields, ("per_page", str(MAX_PAGE_SIZE)), ("page", str(page))),
        )
        if not isinstance(payload, dict):
            raise VerificationError(f"{endpoint} response must be a JSON object")
        total = nonnegative_int(payload.get("total_count"), f"{endpoint}.total_count")
        page_values = payload.get(collection_name)
        if not isinstance(page_values, list):
            raise VerificationError(f"{endpoint}.{collection_name} must be a list")
        if len(page_values) > MAX_PAGE_SIZE:
            raise VerificationError(f"{endpoint} returned an oversized page")
        if total > MAX_RESULTS:
            raise VerificationError(f"{endpoint} exceeds the safe pagination limit")
        if expected_total is None:
            expected_total = total
        elif total != expected_total:
            raise VerificationError(f"{endpoint}.total_count changed during pagination")

        for index, value in enumerate(page_values):
            if not isinstance(value, dict):
                raise VerificationError(
                    f"{endpoint}.{collection_name}[{index}] must be an object"
                )
            item_id = positive_int(
                value.get("id"), f"{endpoint}.{collection_name}[{index}].id"
            )
            if item_id in seen_ids:
                raise VerificationError(f"{endpoint} returned duplicate id {item_id}")
            seen_ids.add(item_id)
            values.append(value)

        if len(values) == expected_total:
            return values
        if len(values) > expected_total or not page_values:
            raise VerificationError(f"{endpoint} pagination is inconsistent")

    raise VerificationError(f"{endpoint} pagination did not complete")


def load_required_names(policy_path: Path) -> Tuple[str, ...]:
    try:
        with policy_path.open(encoding="utf-8") as source:
            policy = json.load(source)
    except (OSError, json.JSONDecodeError) as error:
        raise VerificationError(f"cannot read required-check policy: {error}") from error
    if not isinstance(policy, dict):
        raise VerificationError("required-check policy must be a JSON object")
    required = policy.get("required_status_checks")
    if not isinstance(required, dict):
        raise VerificationError("required-check policy has no status-check object")
    checks = required.get("checks")
    if not isinstance(checks, list) or len(checks) != 9:
        raise VerificationError("required-check policy must define exactly nine checks")

    names = []
    for index, check in enumerate(checks):
        if not isinstance(check, dict):
            raise VerificationError(f"required check {index} must be an object")
        names.append(required_string(check.get("context"), f"required check {index}"))
    if len(set(names)) != len(names):
        raise VerificationError("required-check policy contains duplicate names")
    if SKIPPABLE_REQUIRED_JOB not in names:
        raise VerificationError("required-check policy is missing Dependency review")
    return tuple(names)


def canonical_workflow_id(repo: str) -> int:
    # The workflow endpoint exposes the canonical unqualified path. Workflow-run
    # paths may add a ref suffix such as "@main".
    # https://docs.github.com/en/rest/actions/workflows#get-a-workflow
    endpoint = f"repos/{repo}/actions/workflows/ci.yml"
    workflow = gh_api_json(endpoint)
    if not isinstance(workflow, dict):
        raise VerificationError("workflow response must be a JSON object")
    workflow_id = positive_int(workflow.get("id"), "workflow.id")
    path = required_string(workflow.get("path"), "workflow.path")
    if path != EXPECTED_WORKFLOW_PATH:
        raise VerificationError(
            f"ci.yml resolved to unexpected workflow path {path!r}"
        )
    return workflow_id


def repository_name(value, label: str) -> str:
    if not isinstance(value, dict):
        raise VerificationError(f"{label} must be an object")
    return required_string(value.get("full_name"), f"{label}.full_name")


def eligible_run(
    run: Mapping,
    *,
    repo: str,
    sha: str,
    workflow_id: int,
    now: datetime,
    max_age: timedelta,
) -> Tuple[Optional[str], datetime]:
    run_id = positive_int(run.get("id"), "workflow run id")
    actual_workflow_id = positive_int(
        run.get("workflow_id"), f"workflow run {run_id} workflow_id"
    )
    head_branch = required_string(
        run.get("head_branch"), f"workflow run {run_id} head_branch"
    )
    head_sha = required_string(run.get("head_sha"), f"workflow run {run_id} head_sha")
    path = required_string(run.get("path"), f"workflow run {run_id} path")
    event = required_string(run.get("event"), f"workflow run {run_id} event")
    status = required_string(run.get("status"), f"workflow run {run_id} status")
    conclusion = run.get("conclusion")
    if conclusion is not None and (not isinstance(conclusion, str) or not conclusion):
        raise VerificationError(
            f"workflow run {run_id} conclusion must be null or a non-empty string"
        )
    html_url = required_string(
        run.get("html_url"), f"workflow run {run_id} html_url"
    )
    created_at = parse_timestamp(
        run.get("created_at"), f"workflow run {run_id} created_at"
    )
    source_repo = repository_name(run.get("repository"), "workflow run repository")
    head_repo = repository_name(
        run.get("head_repository"), "workflow run head_repository"
    )

    age = now - created_at
    if age < -MAX_FUTURE_CLOCK_SKEW:
        raise VerificationError(f"workflow run {run_id} was created in the future")
    if age < timedelta(0):
        age = timedelta(0)
    expected_url = f"https://github.com/{repo}/actions/runs/{run_id}"
    qualified_path = path.split("@", 1)[0]
    matches = (
        actual_workflow_id == workflow_id
        and head_branch == "main"
        and head_sha == sha
        and qualified_path == EXPECTED_WORKFLOW_PATH
        and event in ALLOWED_EVENTS
        and html_url == expected_url
        and source_repo == repo
        and head_repo == repo
        and age <= max_age
    )
    if not matches:
        return None, created_at
    if status == "completed":
        if conclusion is None:
            raise VerificationError(
                f"completed workflow run {run_id} has no conclusion"
            )
        return ("reusable" if conclusion == "success" else None), created_at
    if status in WAITABLE_STATUSES:
        if conclusion is not None:
            raise VerificationError(
                f"active workflow run {run_id} unexpectedly has a conclusion"
            )
        return "waitable", created_at
    raise VerificationError(
        f"exact-main workflow run {run_id} has unsupported status {status!r}"
    )


def required_jobs_succeeded(
    jobs: Sequence[Mapping],
    *,
    run_id: int,
    sha: str,
    required_names: Sequence[str],
) -> Tuple[bool, str]:
    jobs_by_name: Dict[str, List[Mapping]] = defaultdict(list)
    for index, job in enumerate(jobs):
        actual_run_id = positive_int(job.get("run_id"), f"job {index} run_id")
        actual_sha = required_string(job.get("head_sha"), f"job {index} head_sha")
        name = required_string(job.get("name"), f"job {index} name")
        required_string(job.get("status"), f"job {index} status")
        conclusion = job.get("conclusion")
        if conclusion is not None and not isinstance(conclusion, str):
            raise VerificationError(f"job {index} conclusion has an invalid type")
        if actual_run_id != run_id or actual_sha != sha:
            raise VerificationError(f"job {index} identity does not match run {run_id}")
        jobs_by_name[name].append(job)

    for name in required_names:
        matches = jobs_by_name.get(name, [])
        if len(matches) != 1:
            return False, f"required job {name!r} appeared {len(matches)} times"
        job = matches[0]
        if job["status"] != "completed":
            return False, f"required job {name!r} is not completed"
        allowed = {"success", "skipped"} if name == SKIPPABLE_REQUIRED_JOB else {"success"}
        if job["conclusion"] not in allowed:
            return False, (
                f"required job {name!r} concluded {job['conclusion']!r}"
            )
    return True, ""


def find_reusable_run(
    *,
    repo: str,
    sha: str,
    policy_path: Path,
    now: datetime,
    max_age: timedelta,
) -> Optional[Tuple[int, str, bool]]:
    required_names = load_required_names(policy_path)
    workflow_id = canonical_workflow_id(repo)
    # Deliberately omit the status filter so an existing queued/in-progress
    # exact-main run can be waited instead of cancelled by a duplicate dispatch.
    # Every identity and state field is still verified locally before use.
    # https://docs.github.com/en/rest/actions/workflow-runs#list-workflow-runs-for-a-workflow
    runs_endpoint = f"repos/{repo}/actions/workflows/{workflow_id}/runs"
    runs = paginated_items(
        runs_endpoint,
        "workflow_runs",
        (
            ("branch", "main"),
            ("head_sha", sha),
            ("exclude_pull_requests", "true"),
        ),
    )

    reusable_candidates = []
    waitable_candidates = []
    for run in runs:
        state, created_at = eligible_run(
            run,
            repo=repo,
            sha=sha,
            workflow_id=workflow_id,
            now=now,
            max_age=max_age,
        )
        if state == "reusable":
            reusable_candidates.append((created_at, run))
        elif state == "waitable":
            waitable_candidates.append((created_at, run))
    reusable_candidates.sort(key=lambda value: value[0], reverse=True)
    waitable_candidates.sort(key=lambda value: value[0], reverse=True)

    for _, run in reusable_candidates:
        run_id = positive_int(run.get("id"), "workflow run id")
        # `latest` excludes obsolete rerun attempts; every protected job is
        # checked by exact name and conclusion below.
        # https://docs.github.com/en/rest/actions/workflow-jobs#list-jobs-for-a-workflow-run
        jobs = paginated_items(
            f"repos/{repo}/actions/runs/{run_id}/jobs",
            "jobs",
            (("filter", "latest"),),
        )
        passed, reason = required_jobs_succeeded(
            jobs,
            run_id=run_id,
            sha=sha,
            required_names=required_names,
        )
        if passed:
            return (
                run_id,
                required_string(run.get("html_url"), "workflow run URL"),
                False,
            )
        print(f"CI run {run_id} is not reusable: {reason}", file=sys.stderr)
    if waitable_candidates:
        run = waitable_candidates[0][1]
        return (
            positive_int(run.get("id"), "workflow run id"),
            required_string(run.get("html_url"), "workflow run URL"),
            True,
        )
    return None


def parse_args(argv: Optional[Sequence[str]] = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--policy", required=True, type=Path)
    parser.add_argument("--max-age-hours", type=int, default=24)
    parser.add_argument("--now", help=argparse.SUPPRESS)
    arguments = parser.parse_args(argv)
    if not re.fullmatch(r"[^/\s]+/[^/\s]+", arguments.repo):
        parser.error("--repo must use OWNER/REPO form")
    if not re.fullmatch(r"[0-9a-f]{40}", arguments.sha):
        parser.error("--sha must be a lowercase 40-character commit SHA")
    if arguments.max_age_hours <= 0:
        parser.error("--max-age-hours must be positive")
    return arguments


def main(argv: Optional[Sequence[str]] = None) -> int:
    arguments = parse_args(argv)
    try:
        now = (
            parse_timestamp(arguments.now, "--now")
            if arguments.now
            else datetime.now(timezone.utc)
        )
        reusable = find_reusable_run(
            repo=arguments.repo,
            sha=arguments.sha,
            policy_path=arguments.policy,
            now=now,
            max_age=timedelta(hours=arguments.max_age_hours),
        )
    except VerificationError as error:
        print(f"Reusable CI verification failed: {error}", file=sys.stderr)
        return 2

    if reusable is None:
        print(
            "No reusable exact-main CI run was found within the allowed age.",
            file=sys.stderr,
        )
        return NOT_FOUND_EXIT
    run_id, run_url, waitable = reusable
    print(f"{run_id}\t{run_url}")
    return WAITABLE_EXIT if waitable else 0


if __name__ == "__main__":
    sys.exit(main())
