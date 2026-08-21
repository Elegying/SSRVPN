import copy
import json
import os
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "find-reusable-main-ci.py"
POLICY = ROOT / ".github" / "main-branch-protection.json"


class FindReusableMainCiTest(unittest.TestCase):
    REPO = "Elegying/SSRVPN"
    SHA = "a" * 40
    NOW = "2026-08-21T12:00:00Z"
    RUN_ID = 777
    WORKFLOW_ID = 321
    REQUIRED = (
        "Full-history secret scan",
        "Dependency review",
        "CodeQL (Actions)",
        "Prepare verified core assets",
        "macOS native unit tests",
        "Workspace checks",
        "Android",
        "macOS",
        "Windows",
    )

    def _workflow(self) -> dict:
        return {
            "id": self.WORKFLOW_ID,
            "path": ".github/workflows/ci.yml",
            "state": "active",
        }

    def _run(self, *, event: str = "push", created_at: str = None) -> dict:
        return {
            "id": self.RUN_ID,
            "workflow_id": self.WORKFLOW_ID,
            "head_branch": "main",
            "head_sha": self.SHA,
            "path": ".github/workflows/ci.yml@refs/heads/main",
            "event": event,
            "status": "completed",
            "conclusion": "success",
            "html_url": (
                "https://github.com/Elegying/SSRVPN/actions/runs/777"
            ),
            "created_at": created_at or "2026-08-21T11:00:00Z",
            "repository": {"full_name": self.REPO},
            "head_repository": {"full_name": self.REPO},
        }

    def _jobs(self) -> dict:
        jobs = []
        for index, name in enumerate(self.REQUIRED, start=1):
            jobs.append(
                {
                    "id": index,
                    "run_id": self.RUN_ID,
                    "head_sha": self.SHA,
                    "name": name,
                    "status": "completed",
                    "conclusion": (
                        "skipped" if name == "Dependency review" else "success"
                    ),
                }
            )
        for index, name in enumerate(
            ("Windows policy tests", "Windows build"), start=100
        ):
            jobs.append(
                {
                    "id": index,
                    "run_id": self.RUN_ID,
                    "head_sha": self.SHA,
                    "name": name,
                    "status": "completed",
                    "conclusion": "success",
                }
            )
        return {"total_count": len(jobs), "jobs": jobs}

    def _invoke(
        self,
        *,
        workflow=None,
        runs=None,
        jobs=None,
        workflow_raw: str = None,
        runs_raw: str = None,
        jobs_raw: str = None,
        fail_contains: str = "",
        policy=None,
    ):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fake_bin = root / "bin"
            jobs_dir = root / "jobs"
            fake_bin.mkdir()
            jobs_dir.mkdir()
            workflow_path = root / "workflow.json"
            runs_path = root / "runs.json"
            policy_path = root / "policy.json"
            command_log = root / "commands.log"

            workflow_path.write_text(
                workflow_raw
                if workflow_raw is not None
                else json.dumps(workflow or self._workflow()),
                encoding="utf-8",
            )
            run_values = runs if runs is not None else [self._run()]
            runs_path.write_text(
                runs_raw
                if runs_raw is not None
                else json.dumps(
                    {"total_count": len(run_values), "workflow_runs": run_values}
                ),
                encoding="utf-8",
            )
            jobs_path = jobs_dir / f"{self.RUN_ID}.json"
            jobs_path.write_text(
                jobs_raw
                if jobs_raw is not None
                else json.dumps(jobs or self._jobs()),
                encoding="utf-8",
            )
            policy_path.write_text(
                json.dumps(policy, indent=2)
                if policy is not None
                else POLICY.read_text(encoding="utf-8"),
                encoding="utf-8",
            )

            gh = fake_bin / "gh"
            gh.write_text(
                textwrap.dedent(
                    r"""
                    #!/usr/bin/env bash
                    set -euo pipefail
                    printf '%s\n' "$*" >> "$FAKE_COMMAND_LOG"
                    if [ -n "$FAKE_FAIL_CONTAINS" ] &&
                      [[ "$*" == *"$FAKE_FAIL_CONTAINS"* ]]; then
                      printf 'simulated GitHub API failure\n' >&2
                      exit 1
                    fi
                    if [[ "$*" == *'/actions/workflows/ci.yml'* ]]; then
                      cat "$FAKE_WORKFLOW_JSON"
                      exit 0
                    fi
                    if [[ "$*" =~ /actions/workflows/[0-9]+/runs ]]; then
                      cat "$FAKE_RUNS_JSON"
                      exit 0
                    fi
                    if [[ "$*" =~ /actions/runs/([0-9]+)/jobs ]]; then
                      cat "$FAKE_JOBS_DIR/${BASH_REMATCH[1]}.json"
                      exit 0
                    fi
                    printf 'unexpected gh api request: %s\n' "$*" >&2
                    exit 2
                    """
                ).lstrip(),
                encoding="utf-8",
            )
            gh.chmod(gh.stat().st_mode | stat.S_IXUSR)

            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
                    "FAKE_COMMAND_LOG": str(command_log),
                    "FAKE_FAIL_CONTAINS": fail_contains,
                    "FAKE_WORKFLOW_JSON": str(workflow_path),
                    "FAKE_RUNS_JSON": str(runs_path),
                    "FAKE_JOBS_DIR": str(jobs_dir),
                }
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--repo",
                    self.REPO,
                    "--sha",
                    self.SHA,
                    "--policy",
                    str(policy_path),
                    "--max-age-hours",
                    "24",
                    "--now",
                    self.NOW,
                ],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            commands = (
                command_log.read_text(encoding="utf-8")
                if command_log.exists()
                else ""
            )
            return result, commands

    def test_reuses_push_or_dispatch_only_after_exact_job_verification(self) -> None:
        for event in ("push", "workflow_dispatch"):
            with self.subTest(event=event):
                result, commands = self._invoke(runs=[self._run(event=event)])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    result.stdout.strip(),
                    "777\thttps://github.com/Elegying/SSRVPN/actions/runs/777",
                )
                self.assertIn("/actions/workflows/ci.yml", commands)
                self.assertIn("/actions/workflows/321/runs", commands)
                self.assertIn("head_sha=" + self.SHA, commands)
                self.assertIn("branch=main", commands)
                self.assertIn("status=success", commands)
                self.assertIn("/actions/runs/777/jobs", commands)
                self.assertIn("filter=latest", commands)

    def test_run_identity_mismatch_or_pull_request_is_not_reused(self) -> None:
        mutations = {
            "pull request": ("event", "pull_request"),
            "other branch": ("head_branch", "release"),
            "other sha": ("head_sha", "b" * 40),
            "other path": ("path", ".github/workflows/release.yml@main"),
            "other workflow": ("workflow_id", 999),
            "failed conclusion": ("conclusion", "failure"),
            "incomplete status": ("status", "queued"),
            "other repository": (
                "repository",
                {"full_name": "attacker/SSRVPN"},
            ),
            "other head repository": (
                "head_repository",
                {"full_name": "attacker/SSRVPN"},
            ),
        }
        for label, (field, value) in mutations.items():
            candidate = self._run()
            candidate[field] = value
            with self.subTest(label=label):
                result, commands = self._invoke(runs=[candidate])
                self.assertEqual(result.returncode, 3, result.stderr)
                self.assertNotIn("/actions/runs/777/jobs", commands)

    def test_run_age_boundary_is_24_hours(self) -> None:
        accepted, _ = self._invoke(
            runs=[self._run(created_at="2026-08-20T12:00:00Z")]
        )
        expired, commands = self._invoke(
            runs=[self._run(created_at="2026-08-20T11:59:59Z")]
        )

        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual(expired.returncode, 3, expired.stderr)
        self.assertNotIn("/actions/runs/777/jobs", commands)

    def test_each_required_job_must_appear_once_with_allowed_conclusion(self) -> None:
        cases = {}

        missing = self._jobs()
        missing["jobs"] = [
            job for job in missing["jobs"] if job["name"] != "Android"
        ]
        missing["total_count"] -= 1
        cases["missing"] = missing

        duplicate = self._jobs()
        repeated = copy.deepcopy(duplicate["jobs"][0])
        repeated["id"] = 999
        duplicate["jobs"].append(repeated)
        duplicate["total_count"] += 1
        cases["duplicate"] = duplicate

        failed = self._jobs()
        next(job for job in failed["jobs"] if job["name"] == "Android")[
            "conclusion"
        ] = "failure"
        cases["failed"] = failed

        skipped = self._jobs()
        next(job for job in skipped["jobs"] if job["name"] == "Android")[
            "conclusion"
        ] = "skipped"
        cases["unexpected skip"] = skipped

        dependency_failure = self._jobs()
        next(
            job
            for job in dependency_failure["jobs"]
            if job["name"] == "Dependency review"
        )["conclusion"] = "failure"
        cases["dependency failure"] = dependency_failure

        for label, jobs in cases.items():
            with self.subTest(label=label):
                result, _ = self._invoke(jobs=jobs)
                self.assertEqual(result.returncode, 3, result.stderr)

    def test_no_matching_or_expired_run_has_distinct_fallback_exit(self) -> None:
        no_runs, commands = self._invoke(runs=[])
        self.assertEqual(no_runs.returncode, 3, no_runs.stderr)
        self.assertNotIn("/actions/runs/", commands)

    def test_api_or_json_anomaly_fails_closed_instead_of_falling_back(self) -> None:
        cases = (
            {"workflow_raw": "{"},
            {"runs_raw": "{"},
            {"jobs_raw": "{"},
            {"fail_contains": "/actions/workflows/321/runs"},
        )
        for arguments in cases:
            with self.subTest(arguments=arguments):
                result, _ = self._invoke(**arguments)
                self.assertNotIn(result.returncode, (0, 3), result.stderr)

    def test_canonical_workflow_path_mismatch_is_an_error(self) -> None:
        workflow = self._workflow()
        workflow["path"] = ".github/workflows/release.yml"
        result, commands = self._invoke(workflow=workflow)

        self.assertNotIn(result.returncode, (0, 3), result.stderr)
        self.assertNotIn("/actions/workflows/321/runs", commands)

    def test_policy_must_define_nine_unique_required_names(self) -> None:
        policy = json.loads(POLICY.read_text(encoding="utf-8"))
        policy["required_status_checks"]["checks"].pop()
        result, commands = self._invoke(policy=policy)

        self.assertNotIn(result.returncode, (0, 3), result.stderr)
        self.assertEqual(commands, "")


if __name__ == "__main__":
    unittest.main()
