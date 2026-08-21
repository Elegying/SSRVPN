import os
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "prepare-release.yml"
PREPARER = ROOT / "scripts" / "prepare-release.sh"


class PrepareReleaseWorkflowTest(unittest.TestCase):
    BASE_SHA = "a" * 40
    BRANCH_SHA = "b" * 40
    MERGED_SHA = "c" * 40

    def _write_executable(self, path: Path, content: str) -> None:
        path.write_text(textwrap.dedent(content), encoding="utf-8")
        path.chmod(path.stat().st_mode | stat.S_IXUSR)

    def _run_preparer(
        self,
        *,
        geoip_changed: bool,
        fail_branch_ci: bool = False,
        fail_main_ci: bool = False,
        fail_release_dispatch: bool = False,
        reuse_main_ci: bool = False,
        malformed_reuse_api: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], str, str, str]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            scripts = root / "scripts"
            fake_bin = root / "fake-bin"
            docs = root / "docs"
            github = root / ".github"
            shared = root / "packages" / "ssrvpn_shared" / "lib" / "constants"
            android = root / "SSRVPN_Android"
            for directory in (scripts, fake_bin, docs, github, shared, android):
                directory.mkdir(parents=True, exist_ok=True)
            shutil.copy2(PREPARER, scripts / PREPARER.name)
            shutil.copy2(
                ROOT / "scripts" / "verify_main_branch_protection.py",
                scripts / "verify_main_branch_protection.py",
            )
            shutil.copy2(
                ROOT / ".github" / "main-branch-protection.json",
                github / "main-branch-protection.json",
            )
            (docs / "GEOIP_SOURCE.txt").write_text(
                "Release tag: 2026-08-02\n", encoding="utf-8"
            )
            (shared / "app_constants.dart").write_text(
                "static const String appVersion = '4.0.2';\n",
                encoding="utf-8",
            )
            (android / "pubspec.yaml").write_text(
                "version: 4.0.2+4002\n", encoding="utf-8"
            )

            command_log = root / "commands.log"
            current_sha = root / "current-sha"
            main_sha = root / "main-sha"
            output = root / "github-output"
            summary = root / "summary"
            current_sha.write_text(self.BASE_SHA, encoding="utf-8")
            main_sha.write_text(self.BASE_SHA, encoding="utf-8")

            self._write_executable(
                fake_bin / "python3",
                r"""
                #!/usr/bin/env bash
                set -euo pipefail
                if [ "${1:-}" = - ]; then
                  exec "$REAL_PYTHON" "$@"
                fi
                printf 'python3 %s\n' "$*" >> "$FAKE_COMMAND_LOG"
                if [ "${1:-}" = scripts/find-reusable-main-ci.py ]; then
                  if [ "$FAKE_MALFORMED_REUSE_API" = true ]; then
                    printf 'simulated reusable-CI API error\n' >&2
                    exit 2
                  fi
                  if [ "$FAKE_REUSE_MAIN_CI" = true ]; then
                    printf '777\thttps://github.com/Elegying/SSRVPN/actions/runs/777\n'
                    exit 0
                  fi
                  exit 3
                fi
                if [ "${1:-}" = scripts/verify_main_branch_protection.py ]; then
                  cat >/dev/null
                  exit 0
                fi
                if [ "${1:-}" = scripts/sync-geoip-metadb.py ] &&
                  [ "$FAKE_GEOIP_CHANGED" = true ]; then
                  printf 'Upstream SHA256: refreshed\n' >> docs/GEOIP_SOURCE.txt
                fi
                exit 0
                """,
            )
            self._write_executable(
                fake_bin / "bash",
                r"""
                #!/usr/bin/env bash
                set -euo pipefail
                case "${1:-}" in
                  scripts/check-version-sync.sh|scripts/bootstrap-core-assets.sh|scripts/verify-core-assets.sh)
                    printf 'bash %s\n' "$*" >> "$FAKE_COMMAND_LOG"
                    exit 0
                    ;;
                esac
                exec /bin/bash "$@"
                """,
            )
            self._write_executable(
                fake_bin / "git",
                r"""
                #!/usr/bin/env bash
                set -euo pipefail
                printf 'git %s\n' "$*" >> "$FAKE_COMMAND_LOG"
                command=${1:-}
                shift || true
                case "$command" in
                  fetch|config|switch|add)
                    exit 0
                    ;;
                  rev-parse)
                    if [ "${1:-}" = --verify ]; then shift; fi
                    expression=${1:-}
                    case "$expression" in
                      HEAD*commit*) cat "$FAKE_CURRENT_SHA" ;;
                      origin/main*commit*) cat "$FAKE_MAIN_SHA" ;;
                      *tree*) printf '%s\n' "$FAKE_TREE_SHA" ;;
                      *) exit 2 ;;
                    esac
                    ;;
                  tag)
                    if [ "${1:-}" = --list ]; then
                      printf 'v4.0.1\n'
                    fi
                    ;;
                  show)
                    printf 'version: 4.0.1+4001\n'
                    ;;
                  ls-remote)
                    exit 2
                    ;;
                  diff)
                    if [ "${1:-}" = --quiet ]; then
                      if [ "$FAKE_GEOIP_CHANGED" = true ]; then exit 1; fi
                      exit 0
                    fi
                    exit 0
                    ;;
                  ls-files)
                    exit 0
                    ;;
                  commit)
                    printf '%s' "$FAKE_BRANCH_SHA" > "$FAKE_CURRENT_SHA"
                    ;;
                  push)
                    exit 0
                    ;;
                  *)
                    printf 'unexpected fake git command: %s %s\n' "$command" "$*" >&2
                    exit 2
                    ;;
                esac
                """,
            )
            self._write_executable(
                fake_bin / "gh",
                r"""
                #!/usr/bin/env bash
                set -euo pipefail
                printf 'gh %s\n' "$*" >> "$FAKE_COMMAND_LOG"
                command=${1:-}
                shift || true
                case "$command" in
                  api)
                    if [[ "$*" == *'/branches/main/protection'* ]]; then
                      printf '{}\n'
                      exit 0
                    fi
                    if [[ "$*" == *'/releases/tags/'* ]]; then
                      printf 'gh: Not Found (HTTP 404)\n' >&2
                      exit 1
                    fi
                    if [[ "$*" == *'/workflows/ci.yml/dispatches'* ]]; then
                      if [[ "$*" == *'ref=main'* ]]; then
                        printf '{"workflow_run_id":102,"html_url":"https://github.com/Elegying/SSRVPN/actions/runs/102"}\n'
                      else
                        printf '{"workflow_run_id":101,"html_url":"https://github.com/Elegying/SSRVPN/actions/runs/101"}\n'
                      fi
                      exit 0
                    fi
                    if [[ "$*" == *'/workflows/release.yml/dispatches'* ]]; then
                      if [ "$FAKE_FAIL_RELEASE_DISPATCH" = true ]; then
                        exit 1
                      fi
                      printf '{"workflow_run_id":103,"html_url":"https://github.com/Elegying/SSRVPN/actions/runs/103"}\n'
                      exit 0
                    fi
                    exit 2
                    ;;
                  run)
                    if [ "${1:-}" = watch ] && [ "${2:-}" = 101 ] &&
                      [ "$FAKE_FAIL_BRANCH_CI" = true ]; then
                      exit 1
                    fi
                    if [ "${1:-}" = watch ] && [ "${2:-}" = 102 ] &&
                      [ "$FAKE_FAIL_MAIN_CI" = true ]; then
                      exit 1
                    fi
                    exit 0
                    ;;
                  pr)
                    subcommand=${1:-}
                    shift || true
                    case "$subcommand" in
                      create)
                        printf 'https://github.com/Elegying/SSRVPN/pull/84\n'
                        ;;
                      checks)
                        if [[ "$*" == *"--jq length"* ]]; then
                          printf '9\n'
                        elif [ "$FAKE_FAIL_BRANCH_CI" = true ]; then
                          exit 1
                        fi
                        ;;
                      merge)
                        printf '%s' "$FAKE_MERGED_SHA" > "$FAKE_MAIN_SHA"
                        ;;
                      view)
                        if [[ "$*" == *'.mergeCommit.oid'* ]]; then
                          printf '%s\n' "$FAKE_MERGED_SHA"
                        else
                          printf 'MERGED\n'
                        fi
                        ;;
                      *) exit 2 ;;
                    esac
                    ;;
                  *) exit 2 ;;
                esac
                """,
            )

            environment = os.environ.copy()
            environment.update(
                {
                    "PATH": f"{fake_bin}{os.pathsep}{environment['PATH']}",
                    "REAL_PYTHON": sys.executable,
                    "FAKE_COMMAND_LOG": str(command_log),
                    "FAKE_CURRENT_SHA": str(current_sha),
                    "FAKE_MAIN_SHA": str(main_sha),
                    "FAKE_BASE_SHA": self.BASE_SHA,
                    "FAKE_BRANCH_SHA": self.BRANCH_SHA,
                    "FAKE_MERGED_SHA": self.MERGED_SHA,
                    "FAKE_TREE_SHA": "d" * 40,
                    "FAKE_GEOIP_CHANGED": str(geoip_changed).lower(),
                    "FAKE_FAIL_BRANCH_CI": str(fail_branch_ci).lower(),
                    "FAKE_FAIL_MAIN_CI": str(fail_main_ci).lower(),
                    "FAKE_FAIL_RELEASE_DISPATCH": str(
                        fail_release_dispatch
                    ).lower(),
                    "FAKE_REUSE_MAIN_CI": str(reuse_main_ci).lower(),
                    "FAKE_MALFORMED_REUSE_API": str(
                        malformed_reuse_api
                    ).lower(),
                    "GITHUB_REPOSITORY": "Elegying/SSRVPN",
                    "GITHUB_RUN_ID": "9001",
                    "GITHUB_RUN_ATTEMPT": "1",
                    "GITHUB_OUTPUT": str(output),
                    "GITHUB_STEP_SUMMARY": str(summary),
                }
            )
            result = subprocess.run(
                ["/bin/bash", str(scripts / PREPARER.name), "v4.0.2"],
                cwd=root,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            return (
                result,
                command_log.read_text(encoding="utf-8"),
                output.read_text(encoding="utf-8") if output.exists() else "",
                summary.read_text(encoding="utf-8") if summary.exists() else "",
            )

    def test_workflow_is_manual_serialized_and_least_privilege(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn("name: Prepare Release", workflow)
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("tag:", workflow)
        self.assertIn("type: string", workflow)
        self.assertNotIn("\n  push:\n", workflow)
        self.assertNotIn("\n  schedule:\n", workflow)
        self.assertIn("group: ssrvpn-release-preparation", workflow)
        self.assertIn("cancel-in-progress: false", workflow)
        self.assertIn("actions: write", workflow)
        self.assertIn("contents: write", workflow)
        self.assertIn("pull-requests: write", workflow)
        self.assertNotIn("packages: write", workflow)
        self.assertIn("GH_TOKEN: ${{ github.token }}", workflow)
        self.assertIn("GITHUB_TOKEN: ${{ github.token }}", workflow)
        self.assertIn("ref: main", workflow)
        self.assertIn("fetch-depth: 0", workflow)
        self.assertIn("RELEASE_TAG: ${{ inputs.tag }}", workflow)
        self.assertIn('bash scripts/prepare-release.sh "$RELEASE_TAG"', workflow)
        self.assertNotIn(
            'bash scripts/prepare-release.sh "${{ inputs.tag }}"', workflow
        )

    def test_preparer_tags_only_after_geoip_and_exact_main_ci(self) -> None:
        preparer = PREPARER.read_text(encoding="utf-8")

        protection = preparer.index("verify_main_branch_protection")
        bootstrap = preparer.index("bash scripts/bootstrap-core-assets.sh")
        sync = preparer.index("python3 scripts/sync-geoip-metadb.py")
        mirror = preparer.index("python3 scripts/ensure-geoip-mirror.py --upload")
        verify = preparer.index("bash scripts/verify-core-assets.sh")
        create_pr = preparer.index("gh pr create")
        branch_checks = preparer.index(
            'wait_for_pull_request_checks "$pr_number" "$branch_ci_url"'
        )
        merge_pr = preparer.index("gh pr merge")
        main_ci = preparer.index('dispatch_workflow "ci.yml" main')
        reusable_ci = preparer.index("find-reusable-main-ci.py")
        final_freshness = preparer.index(
            "python3 scripts/sync-geoip-metadb.py --check"
        )
        create_tag = preparer.index('git tag -a "$tag"')
        push_tag = preparer.index('git push origin "refs/tags/$tag"')
        release = preparer.index('dispatch_workflow "release.yml" "$tag"')

        self.assertLess(protection, bootstrap)
        self.assertLess(bootstrap, sync)
        self.assertLess(sync, mirror)
        self.assertLess(mirror, verify)
        self.assertLess(verify, create_pr)
        self.assertLess(create_pr, branch_checks)
        self.assertLess(branch_checks, merge_pr)
        self.assertLess(merge_pr, reusable_ci)
        self.assertLess(reusable_ci, main_ci)
        self.assertLess(main_ci, final_freshness)
        self.assertLess(final_freshness, create_tag)
        self.assertLess(create_tag, push_tag)
        self.assertLess(push_tag, release)
        self.assertIn('wait_for_workflow "$release_run_id"', preparer)
        self.assertIn("git add -- docs/GEOIP_SOURCE.txt", preparer)
        self.assertNotIn("git add .", preparer)
        self.assertNotIn("git push --force", preparer)
        self.assertNotIn("--admin", preparer)
        self.assertNotIn('dispatch_workflow "ci.yml" "$branch"', preparer)
        self.assertIn("within 30 minutes", preparer)
        self.assertIn("Approve the pending GitHub Actions workflow", preparer)

    def test_existing_tag_or_release_blocks_before_geoip_mutation(self) -> None:
        preparer = PREPARER.read_text(encoding="utf-8")

        remote_tag_guard = preparer.index("refs/tags/$tag")
        release_guard = preparer.index('releases/tags/$tag')
        sync = preparer.index("python3 scripts/sync-geoip-metadb.py")
        self.assertLess(remote_tag_guard, sync)
        self.assertLess(release_guard, sync)

    def test_release_workflow_retains_read_only_freshness_defense(self) -> None:
        workflow = (ROOT / ".github" / "workflows" / "release.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("Require the latest GeoIP snapshot", workflow)
        self.assertIn("python3 scripts/sync-geoip-metadb.py --check", workflow)
        self.assertNotRegex(
            workflow,
            r"(?m)^\s*python3 scripts/sync-geoip-metadb\.py\s*$",
        )

    def test_changed_geoip_runs_both_ci_gates_before_release(self) -> None:
        result, commands, output, summary = self._run_preparer(
            geoip_changed=True
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        create_pr = commands.index("gh pr create")
        branch_checks = commands.index("gh pr checks 84")
        merge_pr = commands.index("gh pr merge")
        main_dispatch = commands.index("ref=main")
        tag_push = commands.index("git push origin refs/tags/v4.0.2")
        release_dispatch = commands.index("workflows/release.yml/dispatches")
        self.assertLess(create_pr, branch_checks)
        self.assertLess(branch_checks, merge_pr)
        self.assertLess(merge_pr, main_dispatch)
        self.assertLess(main_dispatch, tag_push)
        self.assertLess(tag_push, release_dispatch)
        self.assertIn("geoip_changed=true", output)
        self.assertIn("geoip_pr_url=https://github.com/Elegying/SSRVPN/pull/84", output)
        self.assertIn("Release workflow:", summary)

    def test_pull_request_ci_failure_preserves_pr_without_tag(self) -> None:
        result, commands, output, _ = self._run_preparer(
            geoip_changed=True,
            fail_branch_ci=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gh pr create", commands)
        self.assertIn("gh pr checks 84", commands)
        self.assertNotIn("ref=automation/release-4.0.2-geoip-9001-1", commands)
        self.assertNotIn("gh run watch 101", commands)
        self.assertNotIn("git push origin --delete", commands)
        self.assertNotIn("git push origin refs/tags/v4.0.2", commands)
        self.assertNotIn("workflows/release.yml/dispatches", commands)
        self.assertEqual(output, "")

    def test_current_geoip_skips_pr_but_rechecks_main_before_release(self) -> None:
        result, commands, output, _ = self._run_preparer(geoip_changed=False)

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("gh pr create", commands)
        self.assertNotIn("HEAD:refs/heads/automation/", commands)
        main_dispatch = commands.index("workflows/ci.yml/dispatches")
        tag_push = commands.index("git push origin refs/tags/v4.0.2")
        release_dispatch = commands.index("workflows/release.yml/dispatches")
        self.assertLess(main_dispatch, tag_push)
        self.assertLess(tag_push, release_dispatch)
        self.assertIn("geoip_changed=false", output)

    def test_recent_exact_main_ci_is_reused_without_dispatch_or_watch(self) -> None:
        result, commands, output, summary = self._run_preparer(
            geoip_changed=False,
            reuse_main_ci=True,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        finder = commands.index("python3 scripts/find-reusable-main-ci.py")
        tag_push = commands.index("git push origin refs/tags/v4.0.2")
        self.assertLess(finder, tag_push)
        self.assertNotIn("/workflows/ci.yml/dispatches", commands)
        self.assertNotIn("gh run watch 777", commands)
        self.assertIn(
            "main_ci_url=https://github.com/Elegying/SSRVPN/actions/runs/777",
            output,
        )
        self.assertIn(
            "Exact-main CI: https://github.com/Elegying/SSRVPN/actions/runs/777",
            summary,
        )

    def test_reuse_api_anomaly_stops_before_dispatch_or_tag(self) -> None:
        result, commands, output, _ = self._run_preparer(
            geoip_changed=False,
            malformed_reuse_api=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("python3 scripts/find-reusable-main-ci.py", commands)
        self.assertNotIn("/workflows/ci.yml/dispatches", commands)
        self.assertNotIn("git push origin refs/tags/v4.0.2", commands)
        self.assertNotIn("workflows/release.yml/dispatches", commands)
        self.assertEqual(output, "")

    def test_exact_main_ci_failure_prevents_tag_and_release(self) -> None:
        result, commands, output, _ = self._run_preparer(
            geoip_changed=False,
            fail_main_ci=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("gh run watch 102", commands)
        self.assertNotIn("git push origin refs/tags/v4.0.2", commands)
        self.assertNotIn("workflows/release.yml/dispatches", commands)
        self.assertEqual(output, "")

    def test_release_dispatch_failure_keeps_the_immutable_tag(self) -> None:
        result, commands, output, _ = self._run_preparer(
            geoip_changed=False,
            fail_release_dispatch=True,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("git push origin refs/tags/v4.0.2", commands)
        self.assertIn("workflows/release.yml/dispatches", commands)
        self.assertNotIn("git push origin --delete", commands)
        self.assertEqual(output, "")


if __name__ == "__main__":
    unittest.main()
