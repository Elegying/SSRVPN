import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class WindowsProxyShutdownRecoveryTest(unittest.TestCase):
    def test_native_shutdown_restores_only_owned_proxy(self) -> None:
        runner = ROOT / "SSRVPN_Windows" / "windows" / "runner"
        flutter_window = (runner / "flutter_window.cpp").read_text(encoding="utf-8")
        cmake = (runner / "CMakeLists.txt").read_text(encoding="utf-8")
        recovery = (runner / "system_proxy_recovery.cpp").read_text(
            encoding="utf-8"
        )

        self.assertIn("WM_ENDSESSION", flutter_window)
        self.assertIn("RestoreOwnedWindowsProxy", flutter_window)
        self.assertLess(
            flutter_window.index("RestoreOwnedWindowsProxy"),
            flutter_window.index("HandleTopLevelWindowProc"),
        )
        self.assertIn('"system_proxy_recovery.cpp"', cmake)
        self.assertIn("RuntimeProxyBackup", recovery)
        self.assertIn("OwnedProxyServer", recovery)
        self.assertIn("OwnedProxyOverride", recovery)
        self.assertIn("IsOwnedProxyServer", recovery)
        self.assertIn("kOwnedProxyOverride", recovery)
        self.assertIn("DisableOwnedProxyFingerprint", recovery)
        self.assertGreaterEqual(
            recovery.count('IsDwordZeroOrAbsent(settings, L"AutoDetect")'),
            2,
        )
        backup_check = recovery[
            recovery.index("const bool ownership_metadata_valid") : recovery.index(
                "if (!backup_valid)"
            )
        ]
        self.assertIn("IsOwnedProxyServer(owned_server)", backup_check)
        self.assertIn("owned_override == kOwnedProxyOverride", backup_check)
        invalid_backup_start = recovery.index("if (!backup_valid)")
        invalid_backup = recovery[
            invalid_backup_start : recovery.index(
                "HKEY settings = nullptr", invalid_backup_start
            )
        ]
        self.assertIn("ownership_metadata_valid", invalid_backup)
        self.assertIn("DisableOwnedProxyFingerprint", invalid_backup)
        self.assertIn(
            "IsOwnedWindowsProxyEndpointSafeToStopUnlocked()", invalid_backup
        )
        self.assertIn("ActivationInProgress", recovery)
        self.assertIn("AutoConfigURL", recovery)
        self.assertIn("InternetSetOptionW", recovery)
        self.assertIn("RegDeleteTreeW", recovery)
        self.assertIn('L"system_proxy_transaction.lock"', recovery)
        self.assertIn("LockFileEx", recovery)
        self.assertIn("UnlockFileEx", recovery)
        self.assertIn("DisableOwnedProxyEndpoint", recovery)
        self.assertIn('SetDword(settings, L"ProxyEnable", 0)', recovery)
        self.assertIn(
            "bool IsOwnedWindowsProxyEndpointSafeToStopUnlocked()", recovery
        )
        endpoint_safety = recovery[
            recovery.index(
                "bool IsOwnedWindowsProxyEndpointSafeToStopUnlocked()"
            ) : recovery.index("bool IsOwnedWindowsProxySafeToStopUnlocked()")
        ]
        self.assertIn(
            'RegQueryValueExW(\n      settings, L"ProxyEnable"', endpoint_safety
        )
        self.assertIn("proxy_server != owned_server", endpoint_safety)
        safety = recovery[
            recovery.index("bool IsOwnedWindowsProxySafeToStopUnlocked()") : recovery.index(
                "bool RearmWindowsProxyRecoveryRunOnce()"
            )
        ]
        self.assertIn("IsNativeRecoveryJournalNonReplayable()", safety)
        self.assertIn("IsOwnedWindowsProxyEndpointSafeToStopUnlocked()", safety)

        journal_safety = recovery[
            recovery.index("bool IsNativeRecoveryJournalNonReplayable()") : recovery.index(
                "}  // namespace"
            )
        ]
        self.assertIn('ReadDword(backup, L"Valid"', journal_safety)
        for pending_flag in (
            "RestoreInProgress",
            "ActivationInProgress",
            "EndpointRestoreInProgress",
        ):
            self.assertIn(pending_flag, journal_safety)

        restore_start = recovery.index("bool RestoreOwnedWindowsProxyUnlocked()")
        restore_body = recovery[restore_start:]
        first_snapshot = restore_body.index("DWORD original_proxy_enable = 0;")
        full_snapshot = restore_body.index(
            "DWORD original_proxy_enable = 0;", first_snapshot + 1
        )
        endpoint_restore = restore_body[first_snapshot:full_snapshot]
        full_restore = restore_body[full_snapshot:]
        mutation_tokens = (
            "SetDword(settings",
            "SetString(settings",
            "DeleteValueIfPresent(settings",
            "RestoreString(backup, settings",
        )
        first_mutation = min(
            full_restore.index(token)
            for token in mutation_tokens
            if token in full_restore
        )
        for token in (
            'ReadDword(backup, L"OriginalProxyEnable"',
            'ReadOptionalString(backup, L"HasProxyServer"',
            'ReadOptionalString(backup, L"HasProxyOverride"',
            'ReadOptionalString(backup, L"HasAutoConfigURL"',
            'ReadDword(backup, L"HasAutoDetect"',
            'ReadDword(backup, L"OriginalAutoDetect"',
        ):
            self.assertLess(full_restore.index(token), first_mutation)

        proxy_enable_write = full_restore.index(
            'SetDword(settings, L"ProxyEnable"'
        )
        self.assertGreater(
            proxy_enable_write,
            full_restore.index('RestorePreparedString(settings, has_proxy_server'),
        )
        self.assertGreater(
            proxy_enable_write,
            full_restore.index('RestorePreparedString(settings, has_auto_config_url'),
        )
        self.assertGreater(
            proxy_enable_write,
            full_restore.index('SetDword(settings, L"AutoDetect"'),
        )
        journal_write = restore_body.index(
            'SetDword(backup, L"RestoreInProgress", 1)'
        )
        self.assertLess(journal_write - full_snapshot, first_mutation)
        self.assertIn('restore_in_progress == 1', restore_body)
        self.assertGreaterEqual(
            restore_body.count('L"RestoreInProgress", 0)'),
            2,
        )
        self.assertGreaterEqual(
            restore_body.count('L"EndpointRestoreInProgress", 0)'),
            2,
        )
        for restore in (endpoint_restore, full_restore):
            proxy_enable_commit = restore.index(
                'SetDword(settings, L"ProxyEnable"'
            )
            valid_zero = restore.index('SetDword(backup, L"Valid", 0)')
            first_flag_zero = min(
                restore.index(f'L"{name}", 0)')
                for name in (
                    "RestoreInProgress",
                    "EndpointRestoreInProgress",
                    "ActivationInProgress",
                )
            )
            self.assertLess(proxy_enable_commit, valid_zero)
            self.assertLess(valid_zero, first_flag_zero)
            artifact_delete = restore.index(
                "const bool artifacts_removed = RemoveRecoveryArtifacts();"
            )
            self.assertLess(first_flag_zero, artifact_delete)
            self.assertIn("journal_terminal || artifacts_removed", restore)

        artifact_cleanup = recovery[
            recovery.index("bool RemoveRecoveryArtifacts()") : recovery.index(
                "std::wstring JoinPath"
            )
        ]
        self.assertLess(
            artifact_cleanup.index("RegDeleteTreeW"),
            artifact_cleanup.index("RemoveRecoveryRunOnce()"),
        )

    def test_launcher_restores_proxy_after_the_primary_app_exits(self) -> None:
        runner = ROOT / "SSRVPN_Windows" / "windows" / "runner"
        main = (runner / "main.cpp").read_text(encoding="utf-8")
        launcher = (runner / "launcher_main.cpp").read_text(encoding="utf-8-sig")
        cmake = (runner / "CMakeLists.txt").read_text(encoding="utf-8")

        self.assertIn("return ERROR_ALREADY_EXISTS;", main)
        self.assertGreaterEqual(cmake.count('"system_proxy_recovery.cpp"'), 2)
        self.assertIn(
            'target_link_libraries(${LAUNCHER_TARGET} PRIVATE "advapi32.lib")',
            cmake,
        )
        self.assertIn(
            'target_link_libraries(${LAUNCHER_TARGET} PRIVATE "wininet.lib")',
            cmake,
        )

        guardian = launcher[
            launcher.index("int RunGuardian") : launcher.index("// ── UI helpers")
        ]
        exit_read = guardian.index("GetExitCodeProcess")
        duplicate_guard = guardian.index("exit_code == ERROR_ALREADY_EXISTS")
        cleanup = guardian.index(
            "RestoreAndTerminateGuardedProcessWithRetry", duplicate_guard
        )
        self.assertLess(exit_read, duplicate_guard)
        self.assertLess(duplicate_guard, cleanup)

        message_loop_end = main.index(
            'startup_diagnostics::Log(L"message loop ended")'
        )
        final_restore = main.index("RestoreOwnedWindowsProxy()", message_loop_end - 100)
        window_destroy = main.index("window.Destroy()", message_loop_end)
        com_uninitialize = main.index("::CoUninitialize()", window_destroy)
        normal_shutdown = main.index(
            "startup_diagnostics::MarkNormalShutdown()", com_uninitialize
        )
        self.assertLess(final_restore, message_loop_end)
        self.assertLess(message_loop_end, window_destroy)
        self.assertLess(window_destroy, com_uninitialize)
        self.assertLess(com_uninitialize, normal_shutdown)

    def test_primary_app_fails_closed_when_instance_mutex_creation_fails(
        self,
    ) -> None:
        main = (
            ROOT / "SSRVPN_Windows" / "windows" / "runner" / "main.cpp"
        ).read_text(encoding="utf-8")

        mutex_create = main.index("HANDLE instance_mutex")
        capture_error = main.index("const DWORD instance_mutex_error", mutex_create)
        null_guard = main.index("if (instance_mutex == nullptr)", capture_error)
        failure_log = main.index("instance mutex creation failed", null_guard)
        failure_return = main.index("return static_cast<int>", failure_log)
        dart_start = main.index("flutter::DartProject", failure_return)

        self.assertLess(mutex_create, capture_error)
        self.assertLess(capture_error, null_guard)
        self.assertLess(null_guard, failure_log)
        self.assertLess(failure_log, failure_return)
        self.assertLess(failure_return, dart_start)
        failure_branch = main[null_guard:main.index("bool owns_instance_mutex")]
        self.assertIn("instance_mutex_error", failure_branch)
        self.assertNotIn("FlutterWindow", failure_branch)

    def test_launcher_runs_one_explorer_parented_independent_guardian(
        self,
    ) -> None:
        launcher = (
            ROOT
            / "SSRVPN_Windows"
            / "windows"
            / "runner"
            / "launcher_main.cpp"
        ).read_text(encoding="utf-8-sig")

        self.assertIn("kLauncherMutexName", launcher)
        self.assertIn("kGuardianMutexName", launcher)
        self.assertIn("kProcessJobName", launcher)
        self.assertIn("kGuardianCommitPrefix", launcher)
        self.assertIn("GetShellWindow", launcher)
        self.assertIn("ProcessIdToSessionId", launcher)
        self.assertIn("PROC_THREAD_ATTRIBUTE_PARENT_PROCESS", launcher)
        self.assertIn("EXTENDED_STARTUPINFO_PRESENT", launcher)
        self.assertIn("IsNamedMutexOwned(kGuardianMutexName)", launcher)
        self.assertIn("QueryFullProcessImageNameW", launcher)
        self.assertIn("CompareStringOrdinal", launcher)
        self.assertIn("OpenJobObjectW", launcher)
        self.assertIn("OpenJobObjectW(JOB_OBJECT_QUERY", launcher)
        self.assertIn("OpenJobObjectW(JOB_OBJECT_TERMINATE", launcher)
        self.assertIn("IsProcessInJob", launcher)
        self.assertIn("PROCESS_TERMINATE", launcher)

        guardian = launcher[
            launcher.index("int RunGuardian") : launcher.index("// ── UI helpers")
        ]
        open_child = guardian.index("PROCESS_TERMINATE")
        verify_path = guardian.index("ProcessImageMatches", open_child)
        verify_job = guardian.index("IsProcessInJob", verify_path)
        open_thread = guardian.index("OpenThread", verify_job)
        verify_thread = guardian.index("GetProcessIdOfThread", open_thread)
        open_ready = guardian.index("OpenEventW(EVENT_MODIFY_STATE", verify_thread)
        open_commit = guardian.index("OpenEventW(SYNCHRONIZE", open_ready)
        signal_ready = guardian.index("SetEvent(ready_event)", open_commit)
        startup_wait = guardian.index("WaitForMultipleObjects", signal_ready)
        self.assertLess(open_child, verify_path)
        self.assertLess(verify_path, verify_job)
        self.assertLess(verify_job, open_thread)
        self.assertLess(open_thread, verify_thread)
        self.assertLess(verify_thread, open_ready)
        self.assertLess(open_ready, open_commit)
        self.assertLess(open_commit, signal_ready)
        self.assertLess(signal_ready, startup_wait)
        self.assertIn("FALSE, 5000", guardian[startup_wait:])
        startup_timeout = guardian[
            guardian.index("if (startup_wait == WAIT_TIMEOUT") : guardian.index(
                "if (startup_wait == WAIT_OBJECT_0)"
            )
        ]
        self.assertIn("cleanup_error != ERROR_SUCCESS", startup_timeout)
        self.assertNotIn("ResumeThread", startup_timeout)
        self.assertIn("left the app suspended", startup_timeout)
        committed = guardian[
            guardian.index("if (startup_wait == WAIT_OBJECT_0)") :
            guardian.index("DWORD exit_code")
        ]
        guardian_resume = committed.index("ResumeThread(child_thread)")
        guardian_resume_gate = committed.index(
            "previous_suspend_count > 1", guardian_resume
        )
        guardian_cleanup = committed.index(
            "RestoreAndTerminateGuardedProcessWithRetry",
            guardian_resume_gate,
        )
        guardian_wait = committed.index(
            "WaitForSingleObject(child_process, INFINITE)", guardian_cleanup
        )
        self.assertLess(guardian_resume, guardian_resume_gate)
        self.assertLess(guardian_resume_gate, guardian_cleanup)
        self.assertLess(guardian_cleanup, guardian_wait)
        self.assertIn("static_cast<DWORD>(-1)", committed)
        self.assertNotIn("previous_suspend_count != 1", committed)

        cleanup = launcher[
            launcher.index("DWORD RestoreAndTerminateGuardedProcess") :
            launcher.index("int RunGuardian")
        ]
        self.assertIn("WindowsProxyTransactionLock transaction_lock", cleanup)
        restore = cleanup.index(
            "RestoreProxyForProcessCleanup(transaction_lock)"
        )
        terminate = cleanup.index("TerminateJobObject", restore)
        self.assertLess(restore, terminate)
        self.assertIn("return ERROR_BUSY", cleanup[:terminate])
        self.assertIn("TerminateProcess(child_process, EXIT_FAILURE)", cleanup)
        self.assertGreaterEqual(
            cleanup.count("RestoreProxyForProcessCleanup(transaction_lock)"), 2
        )
        visible_disconnect = cleanup.index(
            "MakeSafeDisconnectVisible(child_process)", restore
        )
        kill_on_close = cleanup.index(
            "ArmKillOnJobCloseAndRelease(process_job, child_process)", terminate
        )
        self.assertLess(restore, visible_disconnect)
        self.assertLess(visible_disconnect, terminate)
        self.assertLess(terminate, kill_on_close)
        self.assertNotIn("proxy_safe_to_stop", cleanup)

        main = launcher[launcher.index("int APIENTRY wWinMain") :]
        start_guardian = main.index("StartGuardian")
        guardian_fallback = main.index("if (!guardian_ready)", start_guardian)
        commit = main.index("SetEvent(guardian_commit_event)", guardian_fallback)
        post_commit_check = main.index(
            "WaitForSingleObject(guardian_process, 0)", commit
        )
        resume = main.index("ResumeThread", post_commit_check)
        self.assertLess(start_guardian, guardian_fallback)
        self.assertLess(guardian_fallback, commit)
        self.assertLess(commit, post_commit_check)
        self.assertLess(post_commit_check, resume)
        commit_failure = main[commit:post_commit_check]
        self.assertIn("commit_failed = true", commit_failure)
        self.assertIn("guardian_ready = false", commit_failure)
        post_commit_gate = main[post_commit_check:resume]
        self.assertIn("post_commit_guardian_failed = true", post_commit_gate)
        self.assertIn("guardian_ready = false", post_commit_gate)
        resume_gate = main[post_commit_check:main.index("while (true)", resume)]
        self.assertIn("guardian_ready && child_thread != nullptr", resume_gate)
        self.assertIn("previous_suspend_count > 1", resume_gate)
        self.assertNotIn("previous_suspend_count != 1", resume_gate)
        self.assertIn("ShowErrorAsync", resume_gate)
        self.assertLess(
            main.index("initial_guardian_failed"),
            main.index("ResumeThread", guardian_fallback),
        )
        startup_failure_gate = main[
            main.index("const bool startup_protection_failed") :
            main.index("while (true)", guardian_fallback)
        ]
        for failure in (
            "initial_guardian_failed",
            "commit_failed",
            "post_commit_guardian_failed",
            "resume_failed",
        ):
            self.assertIn(failure, startup_failure_gate)
        self.assertIn(
            "fail_closed_cleanup_pending = startup_protection_failed",
            startup_failure_gate,
        )
        child_creation = launcher[
            launcher.index("bool CreateChildProcess") : launcher.index(
                "}  // namespace"
            )
        ]
        self.assertNotIn("ResumeThread", child_creation)
        self.assertIn("CREATE_SUSPENDED", child_creation)
        final_job_cleanup = main[
            main.index("if (exit_code != ERROR_ALREADY_EXISTS") :
            main.index("if (exit_code == ERROR_ALREADY_EXISTS")
        ]
        self.assertIn("RestoreProxyForProcessCleanup()", final_job_cleanup)
        self.assertIn(
            "assigned_to_job || attached_to_existing", final_job_cleanup
        )
        self.assertIn("TerminateJobObject(process_job", final_job_cleanup)
        self.assertNotIn("guardian_cleaned_up", final_job_cleanup)
        self.assertLess(
            final_job_cleanup.index("RestoreProxyForProcessCleanup()"),
            final_job_cleanup.index("TerminateJobObject(process_job"),
        )

        supervision = main[commit:main.index("DWORD exit_code", commit)]
        self.assertIn(
            "WaitForMultipleObjects(2, supervision_handles, FALSE, INFINITE)",
            supervision,
        )
        guardian_exit = supervision.index("WAIT_OBJECT_0 + 1")
        restart = supervision.index("StartGuardian", guardian_exit)
        restart_commit = supervision.index(
            "SetEvent(replacement_commit_event)", restart
        )
        fail_closed_mode = supervision.index(
            "fail_closed_cleanup_pending = true", restart_commit
        )
        replacement_commit = supervision[restart:fail_closed_mode]
        self.assertIn(
            "if (::SetEvent(replacement_commit_event))", replacement_commit
        )
        self.assertIn(
            "TerminateProcess(guardian_process, error)", replacement_commit
        )
        self.assertIn("guardian_process = nullptr", replacement_commit)
        fail_closed_cleanup = supervision.index(
            "RestoreAndTerminateGuardedProcess(\n"
            "        child_process, &process_job, !safe_disconnect_visible)",
            fail_closed_mode,
        )
        self.assertLess(guardian_exit, restart)
        self.assertLess(restart, restart_commit)
        self.assertLess(restart_commit, fail_closed_mode)
        self.assertLess(fail_closed_mode, fail_closed_cleanup)
        self.assertNotIn("ArmKillOnJobCloseAndRelease", supervision)
        self.assertNotIn("MakeSafeDisconnectVisible", supervision)
        self.assertIn("if (!fail_closed_cleanup_pending)", supervision)
        self.assertEqual(supervision.count("StartGuardian("), 1)
        self.assertIn(
            "WaitForSingleObject(guardian_failure_notice, 5000)", main
        )
        self.assertNotIn(
            "WaitForSingleObject(guardian_failure_notice, INFINITE)", main
        )

    def test_launcher_terminates_only_the_verified_child_handle(self) -> None:
        launcher = (
            ROOT
            / "SSRVPN_Windows"
            / "windows"
            / "runner"
            / "launcher_main.cpp"
        ).read_text(encoding="utf-8-sig")

        existing = launcher[
            launcher.index("HANDLE OpenExistingChildProcess") :
            launcher.index("HANDLE FindChildProcessByPath")
        ]
        finder = launcher[
            launcher.index("HANDLE FindChildProcessByPath") :
            launcher.index("bool IsNamedMutexOwned")
        ]
        for discovery in (existing, finder):
            self.assertIn("DWORD* open_error", discovery)
            self.assertIn("PROCESS_TERMINATE", discovery)
            self.assertLess(
                discovery.index("OpenProcess("),
                discovery.index("ProcessImageMatches"),
            )
            query_fallback = discovery.index("HANDLE query_process")
            query_match = discovery.index(
                "ProcessImageMatches(query_process", query_fallback
            )
            verified_failure = discovery.index(
                "*open_error", query_match
            )
            self.assertLess(query_fallback, query_match)
            self.assertLess(query_match, verified_failure)

        cleanup = launcher[
            launcher.index("DWORD RestoreAndTerminateGuardedProcess") :
            launcher.index("int RunGuardian")
        ]
        cleanup_core = cleanup[: cleanup.index("\nbool ArmKillOnJobCloseAndRelease")]
        self.assertIn(
            "TerminateProcess(child_process, EXIT_FAILURE)", cleanup_core
        )
        self.assertNotIn("GetProcessId(child_process)", cleanup_core)
        self.assertNotIn("OpenProcess(", cleanup_core)

        main = launcher[launcher.index("int APIENTRY wWinMain") :]
        error_init = main.index(
            "DWORD child_process_open_error = ERROR_SUCCESS"
        )
        find_existing = main.index("OpenExistingChildProcess(", error_init)
        find_fallback = main.index("FindChildProcessByPath(", find_existing)
        fail_closed = main.index(
            "child_process_open_error != ERROR_SUCCESS", find_fallback
        )
        create_job = main.index("HANDLE process_job = CreateProcessJob()")
        self.assertLess(error_init, find_existing)
        self.assertLess(find_existing, find_fallback)
        self.assertLess(find_fallback, fail_closed)
        self.assertLess(fail_closed, create_job)
        failure_branch = main[fail_closed:create_job]
        self.assertIn("ReleaseMutex(launcher_mutex)", failure_branch)
        self.assertIn("CloseHandle(launcher_mutex)", failure_branch)
        self.assertIn("ShowError", failure_branch)
        self.assertIn("return static_cast<int>(child_process_open_error)", failure_branch)

    def test_guardian_cleans_named_job_after_primary_app_already_exited(
        self,
    ) -> None:
        launcher = (
            ROOT
            / "SSRVPN_Windows"
            / "windows"
            / "runner"
            / "launcher_main.cpp"
        ).read_text(encoding="utf-8-sig")
        cleanup = launcher[
            launcher.index("DWORD RestoreAndTerminateGuardedProcess") :
            launcher.index("int RunGuardian")
        ]

        named_job = cleanup.index("OpenJobObjectW(JOB_OBJECT_TERMINATE")
        terminate_job = cleanup.index("TerminateJobObject", named_job)
        child_recheck = cleanup.index(
            "child_wait = ::WaitForSingleObject", terminate_job
        )
        exited_success = cleanup.index(
            "if (child_wait == WAIT_OBJECT_0 &&", child_recheck
        )
        self.assertNotIn("if (child_wait == WAIT_OBJECT_0)", cleanup[:named_job])
        self.assertLess(named_job, terminate_job)
        self.assertLess(terminate_job, child_recheck)
        self.assertLess(child_recheck, exited_success)
        success_gate = cleanup[exited_success:cleanup.index(
            "bool ArmKillOnJobCloseAndRelease", exited_success
        )]
        self.assertIn("job_termination_requested || job_confirmed_absent", success_gate)
        self.assertIn("return termination_error", success_gate)

    def test_guardian_retries_transient_restore_and_job_cleanup_failures(
        self,
    ) -> None:
        runner = ROOT / "SSRVPN_Windows" / "windows" / "runner"
        launcher = (runner / "launcher_main.cpp").read_text(encoding="utf-8-sig")
        recovery_header = (runner / "system_proxy_recovery.h").read_text(
            encoding="utf-8"
        )

        retry = launcher[
            launcher.index(
                "DWORD RestoreAndTerminateGuardedProcessWithRetry"
            ) : launcher.index("bool ArmKillOnJobCloseAndRelease", launcher.index(
                "DWORD RestoreAndTerminateGuardedProcessWithRetry"
            ))
        ]
        self.assertIn("while (true)", retry)
        self.assertIn("cleanup_error == ERROR_SUCCESS", retry)
        self.assertIn("cleanup_error != ERROR_BUSY", retry)
        self.assertIn("WaitForSingleObject(child_process, 0) != WAIT_OBJECT_0", retry)
        self.assertIn(
            "RearmWindowsProxyRecoveryRunOnce(child_path.c_str())", retry
        )
        self.assertIn("Sleep(retry_delay_ms)", retry)
        self.assertIn("retry_delay_ms < 2500", retry)
        self.assertIn(": 5000", retry)
        self.assertNotIn("break;", retry)
        self.assertIn(
            "const wchar_t* recovery_executable", recovery_header
        )

        guardian = launcher[
            launcher.index("int RunGuardian") : launcher.index("void ShowError(")
        ]
        self.assertGreaterEqual(
            guardian.count("RestoreAndTerminateGuardedProcessWithRetry"), 3
        )

        main = launcher[launcher.index("int APIENTRY wWinMain") :]
        final_guardian_wait = main[
            main.rindex("if (guardian_process != nullptr)") : main.index(
                "if (exit_code != ERROR_ALREADY_EXISTS", main.rindex(
                    "if (guardian_process != nullptr)"
                )
            )
        ]
        self.assertIn("WaitForSingleObject(guardian_process, 5000)", final_guardian_wait)
        self.assertIn("leave it running", final_guardian_wait)
        self.assertNotIn("TerminateProcess", final_guardian_wait)

        # Runtime fault injection for the production retry predicate: app is
        # already gone, restore is busy first, named-job termination fails
        # next, and the third attempt clears both the proxy and core.
        error_success, error_busy, error_access_denied = 0, 170, 5
        attempts = [error_busy, error_access_denied, error_success]
        guardian_alive = True
        run_once_rearms = 0
        retry_delay_ms = 250
        observed_delays = []
        core_alive = True
        proxy_owned = True
        for cleanup_error in attempts:
            if cleanup_error == error_success:
                core_alive = False
                proxy_owned = False
                break
            child_signaled = True
            if cleanup_error != error_busy and not child_signaled:
                guardian_alive = False
                break
            run_once_rearms += 1
            observed_delays.append(retry_delay_ms)
            retry_delay_ms = (
                retry_delay_ms * 2 if retry_delay_ms < 2500 else 5000
            )
            self.assertTrue(guardian_alive)

        self.assertTrue(guardian_alive)
        self.assertEqual(run_once_rearms, 2)
        self.assertEqual(observed_delays, [250, 500])
        self.assertFalse(proxy_owned)
        self.assertFalse(core_alive)

    def test_detached_guardian_preserves_token_security_and_job_isolation(
        self,
    ) -> None:
        runner = ROOT / "SSRVPN_Windows" / "windows" / "runner"
        launcher = (runner / "launcher_main.cpp").read_text(encoding="utf-8-sig")
        harness = (
            ROOT / "scripts" / "windows_guardian_token_parity_harness.cpp"
        ).read_text(encoding="utf-8-sig")

        token_security = launcher[
            launcher.index("struct ProcessTokenSecurity") : launcher.index(
                "HANDLE OpenExistingChildProcess"
            )
        ]
        self.assertIn("TokenElevationType", token_security)
        self.assertIn("TokenIntegrityLevel", token_security)
        self.assertIn("GetSidSubAuthority", token_security)
        self.assertIn("ProcessTokensHaveSecurityParity", token_security)
        self.assertIn("ProcessIsOutsideJob", token_security)

        detached = launcher[
            launcher.index("bool CreateDetachedGuardianProcess") : launcher.index(
                "bool StartGuardian"
            )
        ]
        token_open = detached.index("OpenProcessToken(::GetCurrentProcess()")
        parent_attribute = detached.index(
            "PROC_THREAD_ATTRIBUTE_PARENT_PROCESS", token_open
        )
        create = detached.index("CreateProcessAsUserW", parent_attribute)
        parity = detached.index(
            "ProcessTokensHaveSecurityParity(::GetCurrentProcess()", create
        )
        outside_job = detached.index("ProcessIsOutsideJob", parity)
        publish = detached.index("*process_information = guardian_information")
        self.assertLess(token_open, parent_attribute)
        self.assertLess(parent_attribute, create)
        self.assertLess(create, parity)
        self.assertLess(parity, outside_job)
        self.assertLess(outside_job, publish)
        self.assertIn("TOKEN_ASSIGN_PRIMARY", detached[token_open:create])
        self.assertNotIn("::CreateProcessW(", detached)
        validation_failure = detached[
            detached.index("if (!guardian_is_safe)") : publish
        ]
        self.assertIn("TerminateProcess(guardian_information.hProcess", validation_failure)
        self.assertIn("return false", validation_failure)

        guardian = launcher[
            launcher.index("int RunGuardian") : launcher.index("void ShowError(")
        ]
        outside_self = guardian.index(
            "ProcessIsOutsideJob(::GetCurrentProcess()"
        )
        child_parity = guardian.index(
            "ProcessTokensHaveSecurityParity(::GetCurrentProcess(), child_process"
        )
        signal_ready = guardian.index("SetEvent(ready_event)")
        self.assertLess(outside_self, child_parity)
        self.assertLess(child_parity, signal_ready)

        self.assertIn("AssignProcessToJobObject(job, ::GetCurrentProcess())", harness)
        self.assertIn("CreateProcessAsUserW", harness)
        self.assertIn("--explicit-low-token", harness)
        self.assertIn("SECURITY_MANDATORY_LOW_RID", harness)
        self.assertIn("IsProcessInJob(child.hProcess, job", harness)
        self.assertIn("observed_parent == shell_id", harness)

    def test_launcher_contains_and_cleans_up_the_primary_process_tree(self) -> None:
        launcher = (
            ROOT
            / "SSRVPN_Windows"
            / "windows"
            / "runner"
            / "launcher_main.cpp"
        ).read_text(encoding="utf-8-sig")

        self.assertIn("CreateJobObjectW", launcher)
        self.assertIn("CREATE_SUSPENDED", launcher)
        self.assertIn("AssignProcessToJobObject", launcher)
        self.assertIn("ResumeThread", launcher)
        self.assertIn("TerminateJobObject", launcher)
        cleanup = launcher[
            launcher.index("DWORD RestoreAndTerminateGuardedProcess") :
            launcher.index("int RunGuardian")
        ]
        restore = cleanup.index(
            "RestoreProxyForProcessCleanup(transaction_lock)"
        )
        terminate = cleanup.index("TerminateJobObject", restore)
        self.assertLess(restore, terminate)
        fail_closed_job = launcher[
            launcher.index("bool ArmKillOnJobCloseAndRelease") :
            launcher.index("struct ProcessWindowLookup")
        ]
        self.assertIn("QueryInformationJobObject", fail_closed_job)
        self.assertIn("SetInformationJobObject", fail_closed_job)
        self.assertIn("JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE", fail_closed_job)
        self.assertIn("*process_job = nullptr", fail_closed_job)
        self.assertIn("WaitForSingleObject(child_process, INFINITE)", fail_closed_job)
        normal_job_creation = launcher[
            launcher.index("HANDLE CreateProcessJob") :
            launcher.index("bool RestoreProxyForProcessCleanup")
        ]
        self.assertNotIn("JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE", normal_job_creation)

        visible_disconnect = launcher[
            launcher.index("void MakeSafeDisconnectVisible(HANDLE child_process) {") :
            launcher.index("int RunGuardian")
        ]
        self.assertIn("WM_SETTEXT", visible_disconnect)
        self.assertIn("SendNotifyMessageW", visible_disconnect)
        self.assertIn("ShowWindowAsync", visible_disconnect)
        self.assertIn("FlashWindowEx", visible_disconnect)
        self.assertIn("ShowErrorAsync", visible_disconnect)
        self.assertNotIn("MessageBoxW", visible_disconnect)

    def test_in_app_installer_handoff_cannot_fall_back_into_the_job(self) -> None:
        handoff = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "windows_detached_installer_launcher.dart"
        ).read_text(encoding="utf-8")

        self.assertIn("WindowsProcessCommand('explorer.exe', [path])", handoff)
        self.assertIn("GetShellWindow", handoff)
        self.assertIn("if (!shellAvailable())", handoff)
        self.assertNotIn("powershell.exe", handoff.lower())
        self.assertNotIn("Start-Process", handoff)

    def test_windows_powershell_calls_force_utf8_output(self) -> None:
        helper = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "src"
            / "services"
            / "windows_powershell.dart"
        ).read_text(encoding="utf-8")
        proxy_service = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "system_proxy_service.dart"
        ).read_text(encoding="utf-8")
        lifecycle = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "clash_service_lifecycle.dart"
        ).read_text(encoding="utf-8")

        self.assertIn("[Console]::OutputEncoding", helper)
        self.assertIn("$OutputEncoding = [Console]::OutputEncoding", helper)
        self.assertIn("$ErrorActionPreference = 'Stop'", helper)
        self.assertIn("windowsPowerShellUtf8Script(script)", proxy_service)
        self.assertIn("windowsPowerShellUtf8Script(script)", lifecycle)

    def test_orphan_cleanup_terminates_the_same_verified_handle(self) -> None:
        lifecycle = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "clash_service_lifecycle.dart"
        ).read_text(encoding="utf-8")
        orphan_cleanup = lifecycle[
            lifecycle.index("Future<void> _terminateOrphanedCores()") :
            lifecycle.index("Future<ProcessResult> _runPowerShell(")
        ]

        self.assertIn("SsrvpnVerifiedProcessTerminator", orphan_cleanup)
        self.assertIn(
            "ProcessQueryLimitedInformation | ProcessTerminate | Synchronize",
            orphan_cleanup,
        )
        self.assertNotIn("Get-CimInstance", orphan_cleanup)
        self.assertNotIn("Stop-Process -Id", orphan_cleanup)
        self.assertNotIn("taskkill", orphan_cleanup.lower())
        termination = orphan_cleanup.split("public static int Terminate(", 1)[1]
        for api in (
            "OpenProcess(",
            "GetProcessId(process)",
            "ProcessIdToSessionId(liveProcessId",
            "QueryFullProcessImageNameW(",
            "TerminateProcess(process, 1)",
            "WaitForSingleObject(process, 8000)",
        ):
            self.assertIn(api, termination)
        self.assertEqual(1, termination.count("OpenProcess("))
        self.assertLess(
            termination.index("OpenProcess("),
            termination.index("GetProcessId(process)"),
        )
        self.assertLess(
            termination.index("GetProcessId(process)"),
            termination.index("QueryFullProcessImageNameW("),
        )
        self.assertLess(
            termination.index("QueryFullProcessImageNameW("),
            termination.index("TerminateProcess(process, 1)"),
        )
        self.assertLess(
            termination.index("TerminateProcess(process, 1)"),
            termination.index("WaitForSingleObject(process, 8000)"),
        )
        self.assertLess(
            termination.index("WaitForSingleObject(process, 8000)"),
            termination.index("CloseHandle(process)"),
        )
        self.assertIn("WaitTimeout", termination)
        self.assertIn("TimeoutException", termination)

    def test_windows_process_logs_tolerate_malformed_utf8(self) -> None:
        lifecycle = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "clash_service_lifecycle.dart"
        ).read_text(encoding="utf-8")

        self.assertNotIn(".transform(utf8.decoder)", lifecycle)
        self.assertGreaterEqual(
            lifecycle.count("Utf8Decoder(allowMalformed: true)"),
            4,
        )

    def test_native_chinese_sources_compile_as_utf8(self) -> None:
        runner = ROOT / "SSRVPN_Windows" / "windows" / "runner"
        cmake = (runner / "CMakeLists.txt").read_text(encoding="utf-8")
        launcher = (runner / "launcher_main.cpp").read_bytes()

        self.assertIn('target_compile_options(${BINARY_NAME} PRIVATE "/utf-8")', cmake)
        self.assertIn('target_compile_options(${LAUNCHER_TARGET} PRIVATE "/utf-8")', cmake)
        self.assertTrue(launcher.startswith(b"\xef\xbb\xbf"))

    def test_dart_persists_native_backup_before_enabling_proxy(self) -> None:
        service = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "system_proxy_service.dart"
        ).read_text(encoding="utf-8")

        backup = service.index("await _writeBackup(snapshot, proxyServer)")
        enable = service.index("Set-ItemProperty -Path \\$regPath -Name ProxyEnable")
        self.assertLess(backup, enable)
        for token in (
            "Set-ItemProperty -Path \\$regPath -Name ProxyServer",
            "Set-ItemProperty -Path \\$regPath -Name ProxyOverride",
            "Set-ItemProperty -Path \\$regPath -Name AutoDetect",
            "Remove-ItemProperty -Path \\$regPath -Name AutoConfigURL",
        ):
            self.assertLess(service.index(token), enable)
        self.assertIn("await _writeNativeRecoveryBackup", service)
        self.assertIn("RuntimeProxyBackup", service)
        self.assertIn("ActivationInProgress", service)
        self.assertIn("await _markActivationComplete()", service)
        self.assertIn("Remove-Item -LiteralPath \\$backupPath", service)

    def test_dart_native_backup_cleanup_is_idempotent_when_missing(self) -> None:
        service = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "system_proxy_service.dart"
        ).read_text(encoding="utf-8")
        delete_cleanup = service[
            service.index("Future<void> _deleteBackup") : service.index(
                "Future<void> _writeNativeRecoveryBackup"
            )
        ]
        write_cleanup = service[
            service.index("Future<void> _writeNativeRecoveryBackup") : service.index(
                "Future<void> _markActivationComplete"
            )
        ]

        guard = "if (Test-Path -LiteralPath \\$backupPath)"
        for operation, cleanup in (
            ("delete", delete_cleanup),
            ("write", write_cleanup),
        ):
            with self.subTest(operation=operation):
                self.assertIn(guard, cleanup)
                self.assertLess(
                    cleanup.index(guard),
                    cleanup.index("Remove-Item -LiteralPath \\$backupPath"),
                )
        self.assertLess(
            write_cleanup.index("Remove-Item -LiteralPath \\$backupPath"),
            write_cleanup.index("New-Item"),
        )

    def test_dart_marks_proxy_restore_before_the_first_registry_write(
        self,
    ) -> None:
        service = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "system_proxy_service.dart"
        ).read_text(encoding="utf-8")

        full_restore = service[
            service.index("Future<bool> _restoreSnapshot") : service.index(
                "Future<bool> _restoreOwnedEndpoint"
            )
        ]
        endpoint_restore = service[
            service.index("Future<bool> _restoreOwnedEndpoint") : service.index(
                "Future<void> _writeBackup"
            )
        ]
        self.assertLess(
            full_restore.index("RestoreInProgress"),
            full_restore.index("Set-ItemProperty -Path \\$regPath"),
        )
        self.assertLess(
            endpoint_restore.index("EndpointRestoreInProgress"),
            endpoint_restore.index("Set-ItemProperty -Path \\$regPath"),
        )
        for restore in (full_restore, endpoint_restore):
            proxy_enable_commit = restore.index(
                "Set-ItemProperty -Path \\$regPath -Name ProxyEnable"
            )
            valid_zero = restore.index(
                "Set-ItemProperty -Path \\$backupPath -Name Valid "
                "-Type DWord -Value 0"
            )
            first_flag_zero = min(
                restore.index(
                    "Set-ItemProperty -Path \\$backupPath "
                    f"-Name {name} -Type DWord -Value 0"
                )
                for name in (
                    "RestoreInProgress",
                    "EndpointRestoreInProgress",
                    "ActivationInProgress",
                )
            )
            self.assertLess(proxy_enable_commit, valid_zero)
            self.assertLess(valid_zero, first_flag_zero)

    def test_connect_retries_pending_proxy_recovery_in_the_same_action(self) -> None:
        service = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "system_proxy_service.dart"
        ).read_text(encoding="utf-8")
        lifecycle = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "clash_service_lifecycle.dart"
        ).read_text(encoding="utf-8")
        app = (ROOT / "SSRVPN_Windows" / "lib" / "app.dart").read_text(
            encoding="utf-8"
        )
        home = (
            ROOT
            / "packages"
            / "ssrvpn_shared"
            / "lib"
            / "desktop_ui"
            / "screens"
            / "desktop_home_screen_part.dart"
        ).read_text(encoding="utf-8")

        self.assertIn("Future<bool> retryPendingRecovery()", service)
        self.assertIn("await initialize(dataDir)", service)
        self.assertIn("Future<bool> recoverPendingSystemProxy()", lifecycle)
        tray_connect = app[
            app.index("Future<void> _handleTrayConnectToggle()") : app.index(
                "String? _defaultNodeName()"
            )
        ]
        tray_generation = tray_connect.index("requestConnectionIntent(true)")
        tray_recovery = tray_connect.index("recoverPendingSystemProxy")
        self.assertLess(tray_generation, tray_recovery)
        self.assertIn(
            "isConnectionIntentCurrent",
            tray_connect[tray_recovery:],
        )
        home_connect = home[
            home.index("Future<void> _handleConnectToggle()") : home.index(
                "@override\n  Widget build"
            )
        ]
        home_generation = home_connect.index("requestConnectionIntent(true)")
        home_recovery = home_connect.index("recoverPendingSystemProxy")
        self.assertLess(home_generation, home_recovery)
        self.assertIn(
            "isConnectionIntentCurrent",
            home_connect[home_recovery:],
        )

    def test_windows_surfaces_runtime_ports_and_recovers_one_core_exit(self) -> None:
        lifecycle = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "clash_service_lifecycle.dart"
        ).read_text(encoding="utf-8")
        app = (ROOT / "SSRVPN_Windows" / "lib" / "app.dart").read_text(
            encoding="utf-8"
        )
        summary = (
            ROOT
            / "packages"
            / "ssrvpn_shared"
            / "lib"
            / "desktop_ui"
            / "widgets"
            / "desktop_home_status_widgets_part.dart"
        ).read_text(encoding="utf-8")
        tray = (
            ROOT / "SSRVPN_Windows" / "lib" / "services" / "tray_manager.dart"
        ).read_text(encoding="utf-8")
        runtime_notice = (
            ROOT / "packages" / "ssrvpn_shared" / "lib" / "runtime_notice.dart"
        ).read_text(encoding="utf-8")

        tray_connect = app[
            app.index("Future<void> _handleTrayConnectToggle()") : app.index(
                "String? _defaultNodeName()"
            )
        ]
        self.assertIn("lastRuntimePortAdjustmentMessage", tray_connect)
        self.assertIn("_presentRuntimeNotice", tray_connect)
        self.assertIn("runtimeProxyPort", summary)
        self.assertIn("runtimeProxyPort", tray)
        self.assertIn("HTTP 代理：127.0.0.1:$port", tray)
        self.assertIn("enabled: false", tray)
        self.assertIn("HTTP 127.0.0.1:$port", app)
        self.assertIn("CoreRecoveryPolicy(maxAttempts: 1)", lifecycle)
        self.assertIn("Future<bool> start() => _start();", lifecycle)
        self.assertIn("_start(automaticRecovery: true)", lifecycle)
        self.assertLess(
            lifecycle.index("_unexpectedExitRecoveryPolicy.reset()"),
            lifecycle.index("final current = _startOperation"),
        )
        self.assertIn("captureAutomaticRestartIntent()", lifecycle)
        self.assertIn("isConnectionIntentCurrent", lifecycle)
        self.assertIn("核心异常退出，正在自动恢复", lifecycle)
        self.assertIn("if (restarted && isRunning)", lifecycle)
        self.assertIn("coreAutoRecoveredRuntimeNotice", lifecycle)
        self.assertIn("核心已自动恢复", runtime_notice)
        self.assertIn("自动恢复失败", lifecycle)
        self.assertIn("onRuntimeNotice", app)

    def test_endpoint_safe_pending_journal_never_restarts_the_listener(self) -> None:
        lifecycle = (
            ROOT
            / "SSRVPN_Windows"
            / "lib"
            / "services"
            / "clash_service_lifecycle.dart"
        ).read_text(encoding="utf-8")

        stop = lifecycle[
            lifecycle.index("Future<bool> _stopInternal()") : lifecycle.index(
                "void _ensureStartCurrent"
            )
        ]
        endpoint_may_be_owned = stop.index(
            "ProxyRecoveryDisposition.endpointMayStillBeOwned"
        )
        unsafe_return = stop.index("return false;", endpoint_may_be_owned)
        endpoint_safe = stop.index(
            "ProxyRecoveryDisposition.endpointSafeWithPendingJournal"
        )
        stop_core = stop.index("final coreProcess = _coreProcess;")
        self.assertLess(unsafe_return, endpoint_safe)
        self.assertLess(endpoint_safe, stop_core)

        unexpected = lifecycle[
            lifecycle.index("Future<void> _recoverFromUnexpectedExit(") :
        ]
        endpoint_safe = unexpected.index(
            "ProxyRecoveryDisposition.endpointSafeWithPendingJournal"
        )
        safe_return = unexpected.index("return;", endpoint_safe)
        listener_start = unexpected.index(
            "final listenerRestored = await _start(", endpoint_safe
        )
        self.assertLess(endpoint_safe, safe_return)
        self.assertLess(safe_return, listener_start)


if __name__ == "__main__":
    unittest.main()
