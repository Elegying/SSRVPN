part of 'clash_service.dart';

class _DesktopStartCancelled implements Exception {}

enum _VerifiedCoreTermination {
  terminatedOrGone,
  liveIdentityMismatch,
  wrongInstallation,
}

const _tunTeardownTimeoutError = '核心已停止，但 Windows TUN 网卡未在超时前移除；'
    '为避免路由冲突，已阻止再次连接，请保持 SSRVPN 打开并重试断开';
const _tunResidualProbeError = '无法确认旧 Windows TUN 网卡和路由已清理；'
    '为避免死路由，已在启动 Mihomo 前安全中止';

Future<bool> terminateCoreProcess(
  Process process, {
  Duration gracefulTimeout = const Duration(seconds: 3),
  Duration forcedTimeout = const Duration(seconds: 3),
}) async {
  final exitCode = process.exitCode;
  process.kill(ProcessSignal.sigterm);
  try {
    await exitCode.timeout(gracefulTimeout);
    return true;
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    try {
      await exitCode.timeout(forcedTimeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }
}

mixin _WindowsCoreLifecycle on ClashServiceBase {
  late final WindowsTunElevationService _tunElevationService;
  bool _tunElevationRelaunchPending = false;
  // ── Process management ──
  Process? _coreProcess;
  WindowsCorePidRecord? _corePidRecord;
  WindowsCoreIdentityEstablishment? _coreIdentityEstablishment;
  Future<bool>? _startOperation;
  Completer<void>? _startCancellation;
  Future<void>? _stopOperation;
  Future<void>? _exitCleanupOperation;
  Future<void>? _pidCleanupOperation;
  WindowsTunRuntimeProbe? _tunRuntimeProbeOverride;
  WindowsTunResidualProbe? _tunResidualProbeOverride;
  WindowsNetworkInterfaceIdentityProbe? _networkInterfaceIdentityProbeOverride;
  final WindowsTunTeardownGate _tunTeardownGate = WindowsTunTeardownGate();
  Set<WindowsTunInterfaceIdentity> _tunInterfacesBeforeStart = const {};
  String? _lastStopError;
  int _startGeneration = 0;
  bool _coreUsesTun = false;
  bool _stoppingCore = false;
  bool _proxyRecoveryListenerActive = false;
  WindowsTunRuntimeStatus? _lastTunRuntimeObservation;
  final CoreRecoveryPolicy _unexpectedExitRecoveryPolicy = CoreRecoveryPolicy(
    maxAttempts: 2,
  );

  // ── Startup disabled ──
  String? _startupDisabledReason;

  // ── System proxy ──
  final SystemProxyService _proxyService = SystemProxyService();

  // ── Core path ──
  String _corePath = '';

  // ── Getters ──
  bool get isStartupDisabled => _startupDisabledReason != null;
  String? get startupDisabledReason => _startupDisabledReason;

  bool get coreExists => File(_corePath).existsSync();
  String get corePath => _corePath;
  bool get hasPendingSystemProxyRecovery => _proxyService.recoveryPending;

  @protected
  Future<SystemProxyOwnershipStatus> inspectSystemProxyOwnership() =>
      _proxyService.currentSystemProxyOwnershipStatus();

  @protected
  bool get systemProxyOwnershipChangedSinceLastAcquisition =>
      _proxyService.ownershipChangedSinceLastAcquisition;

  @override
  Future<bool> healthCheck() async {
    if (!await super.healthCheck()) return false;
    if (!settings.enableTun) {
      if (isRunning) {
        final ownershipStatus = await inspectSystemProxyOwnership();
        if (ownershipStatus == SystemProxyOwnershipStatus.owned) {
          setLastHealthCheckError(null);
          return true;
        }
        final ownershipError = _proxyService.lastError ?? 'Windows 系统代理所有权无法确认';
        final prefix =
            ownershipStatus == SystemProxyOwnershipStatus.externallyChanged
                ? desktopSystemProxyOwnershipLostPrefix
                : desktopSystemProxyOwnershipUnavailablePrefix;
        setLastHealthCheckError('$prefix $ownershipError');
        return false;
      }
      return true;
    }
    final tun = (await getConfigs())?['tun'];
    if (tun is! Map || tun['enable'] != true) {
      setLastHealthCheckError('Mihomo API 已就绪，但 TUN listener 未启用');
      return false;
    }
    final runtimeStatus = await _probeTunRuntime();
    _recordTunRuntimeObservation(runtimeStatus);
    // Mihomo's API and runtime config are the authoritative lifecycle signal.
    // Windows can temporarily expose a working Wintun adapter as hidden or
    // incomplete, especially on preview builds. Keep the OS-level adapter and
    // route probe advisory so a false negative cannot tear down live traffic.
    setLastHealthCheckError(null);
    return true;
  }

  void _recordTunRuntimeObservation(WindowsTunRuntimeStatus status) {
    if (_lastTunRuntimeObservation == status) return;
    final previous = _lastTunRuntimeObservation;
    _lastTunRuntimeObservation = status;
    if (status == WindowsTunRuntimeStatus.ready) {
      if (previous != null && previous != WindowsTunRuntimeStatus.ready) {
        log('Windows TUN 网卡和路由诊断已恢复');
      }
      return;
    }
    final detail = switch (status) {
      WindowsTunRuntimeStatus.adapterMissing => '未观察到预期 TUN 网卡地址',
      WindowsTunRuntimeStatus.routeMissing => '未观察到完整 TUN 路由',
      WindowsTunRuntimeStatus.probeFailed => 'Windows TUN 状态探针不可用',
      WindowsTunRuntimeStatus.ready => '',
    };
    log('⚠️ $detail；Mihomo API 与 TUN listener 已就绪，本项仅记录诊断告警');
  }

  @override
  Future<bool> diagnosticCoreAvailable() async =>
      _corePath.isNotEmpty &&
      await FileSystemEntity.type(_corePath, followLinks: false) ==
          FileSystemEntityType.file;

  @override
  Future<List<AppDiagnosticCheck>> platformDiagnosticChecks() async => [
        AppDiagnosticCheck(
          id: 'system_proxy',
          title: '系统代理恢复',
          status: _proxyService.recoveryPending
              ? AppDiagnosticStatus.warning
              : AppDiagnosticStatus.passed,
          summary: _proxyService.recoveryPending
              ? '检测到 SSRVPN 自有的待恢复代理状态'
              : '没有待恢复的 SSRVPN 系统代理状态',
          errorCode: _proxyService.recoveryPending
              ? AppErrorCode.proxyRecoveryPending
              : null,
          repairAction: _proxyService.recoveryPending
              ? AppRepairAction.retryOwnedProxyRecovery
              : null,
        ),
      ];

  @override
  Future<AppRepairResult> repairDiagnosticIssue(AppRepairAction action) async {
    if (action != AppRepairAction.retryOwnedProxyRecovery) {
      return super.repairDiagnosticIssue(action);
    }
    if (isRunning) {
      return const AppRepairResult(
        success: false,
        message: '请先断开连接，再修复 SSRVPN 自有的系统代理状态。',
      );
    }
    final recovered = await recoverPendingSystemProxy();
    return AppRepairResult(
      success: recovered,
      message: recovered ? 'SSRVPN 自有的系统代理状态已恢复。' : '系统代理恢复未完成，请复制诊断报告后重试。',
    );
  }

  Future<bool> recoverPendingSystemProxy() async {
    if (!_proxyService.recoveryPending) return true;
    log('检测到上次异常退出留下的系统代理状态，正在重试恢复...');
    final recovered = await _proxyService.retryPendingRecovery();
    if (recovered) {
      setLastStartError(null);
      log('✅ 旧系统代理状态已恢复，本次连接继续');
      return true;
    }
    final reason = _proxyService.lastError ?? '系统代理旧状态恢复失败';
    setLastStartError(reason);
    log('❌ $reason');
    return false;
  }

  // ── Lifecycle overrides ──

  @override
  Future<void> onStopRequired() async {
    await stop();
  }

  @override
  Future<bool> recoverAfterHealthCheckFailure(int connectionGeneration) async {
    if (!isConnectionIntentCurrent(connectionGeneration, connected: true)) {
      await stop();
      return false;
    }
    if (await healthCheck()) {
      setRunning(true);
      return true;
    }
    if (!settings.enableTun) {
      // The API and the system proxy can fail at the same time. healthCheck()
      // returns as soon as the API is unavailable, so inspect ownership again
      // immediately before any stop/restart that could reacquire the proxy.
      final ownershipStatus = await inspectSystemProxyOwnership();
      if (ownershipStatus != SystemProxyOwnershipStatus.owned) {
        final externallyChanged =
            ownershipStatus == SystemProxyOwnershipStatus.externallyChanged;
        // Invalidate intent before asynchronous cleanup so neither the health
        // monitor nor an in-flight recovery can reacquire the system proxy.
        markConnectionLost();
        try {
          await stop();
        } catch (error) {
          log('系统代理所有权失效后的核心清理未完成: $error');
          notifyRuntimeNotice(
            '已取消自动重连，但系统代理或 Mihomo 核心清理状态无法确认；'
            '请在诊断页检查并重试断开，SSRVPN 不会重新接管代理。',
          );
          return false;
        }
        notifyRuntimeNotice(
          externallyChanged
              ? '检测到系统代理已被其他程序接管，SSRVPN 已安全断开且不会覆盖当前代理。'
              : '无法确认当前系统代理所有权，SSRVPN 已安全断开且不会覆盖未知代理状态。',
        );
        return false;
      }
    }
    if (!_unexpectedExitRecoveryPolicy.tryAcquire()) {
      await stop();
      return false;
    }

    notifyRuntimeNotice(
      'Mihomo 持续失去响应，正在执行安全重启'
      '（${_unexpectedExitRecoveryPolicy.attempts}/'
      '${_unexpectedExitRecoveryPolicy.maxAttempts}）…',
    );
    try {
      await stop();
    } catch (error) {
      log('健康检查恢复时停止 Mihomo 失败: $error');
      return false;
    }
    if (!isConnectionIntentCurrent(connectionGeneration, connected: true)) {
      return false;
    }
    if (!settings.enableTun &&
        systemProxyOwnershipChangedSinceLastAcquisition) {
      markConnectionLost();
      notifyRuntimeNotice(
        '系统代理在清理期间发生变化，已取消自动重连；'
        'SSRVPN 不会重新接管当前代理。',
      );
      return false;
    }
    return recoverDesktopConnection(connectionGeneration);
  }

  // ── Windows process management ──

  void disableStartup(String reason) {
    _startupDisabledReason = reason;
    setLastStartError(reason);
    log(reason);
  }

  Future<void> _logCoreVersion() async {
    Process? process;
    try {
      process = await Process.start(_corePath, ['-v']);
      final stdoutFuture = process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final stderrFuture = process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .join();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          process?.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      if (exitCode == -1) {
        log('⚠️ 核心版本检查超时，可能被安全软件拦截');
      } else {
        final output = '${await stdoutFuture}\n${await stderrFuture}'.trim();
        if (exitCode == 0 && output.isNotEmpty) {
          log('核心版本: ${output.replaceAll(RegExp(r'\s+'), ' ')}');
        } else {
          final reason = _describeWindowsExitCode(exitCode);
          log(
            '⚠️ 核心版本检查失败，退出码: $exitCode'
            '${reason == null ? "" : "（$reason）"}',
          );
        }
      }
    } catch (e) {
      log('⚠️ 核心无法执行: $e');
    }
  }

  /// Cleans up cores left behind if the previous app process was terminated.
  Future<void> _terminateOrphanedCores() async {
    if (!Platform.isWindows || _corePath.isEmpty) return;
    final pidFile = File('$configDir${Platform.pathSeparator}mihomo.pid');
    final pidFileType = await FileSystemEntity.type(
      pidFile.path,
      followLinks: false,
    );
    if (pidFileType == FileSystemEntityType.notFound) return;
    if (pidFileType != FileSystemEntityType.file) {
      throw StateError('Mihomo 进程身份记录不是普通文件，已拒绝自动清理');
    }
    final pidFileLength = await pidFile.length();
    if (pidFileLength <= 0 || pidFileLength > maxWindowsCorePidRecordBytes) {
      throw StateError('Mihomo 进程身份记录大小异常，已拒绝自动清理');
    }
    final record = WindowsCorePidRecord.tryParse(await pidFile.readAsString());
    if (record == null) {
      throw StateError(
        'Mihomo 进程身份记录为旧格式或已损坏，无法确认进程归属；'
        '记录已保留，请重新安装或联系支持',
      );
    }
    try {
      final disposition = await _terminateVerifiedCore(record);
      if (disposition == _VerifiedCoreTermination.wrongInstallation) {
        throw StateError('进程身份记录指向其他安装目录，已拒绝清理');
      }
      final recordDeleted = await _deleteCorePid(expectedRecord: record);
      if (!recordDeleted) {
        throw StateError('进程身份记录在清理期间发生变化，已拒绝删除');
      }
      if (disposition == _VerifiedCoreTermination.terminatedOrGone) {
        log('已完成遗留 Mihomo 进程清理');
      }
    } catch (error) {
      throw StateError('无法安全确认并清理遗留核心: $error');
    }
  }

  Future<_VerifiedCoreTermination> _terminateVerifiedCore(
    WindowsCorePidRecord record,
  ) async {
    final encodedExpectedPath = base64Encode(
      utf8.encode(record.canonicalExecutablePath),
    );
    final encodedTrustedPath = base64Encode(utf8.encode(_corePath));
    final script = '''
\$expectedPath = [Text.Encoding]::UTF8.GetString(
  [Convert]::FromBase64String('$encodedExpectedPath'))
\$trustedPath = [Text.Encoding]::UTF8.GetString(
  [Convert]::FromBase64String('$encodedTrustedPath'))
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public static class SsrvpnVerifiedProcessTerminator {
  private const uint ProcessTerminate = 0x0001;
  private const uint ProcessQueryLimitedInformation = 0x1000;
  private const uint Synchronize = 0x00100000;
  private const uint StillActive = 259;
  private const uint WaitObject0 = 0;
  private const uint WaitTimeout = 258;

  [StructLayout(LayoutKind.Sequential)]
  private struct FileTimeParts {
    public uint LowDateTime;
    public uint HighDateTime;
  }

  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern IntPtr OpenProcess(
      uint desiredAccess, bool inheritHandle, uint processId);
  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern uint GetProcessId(IntPtr process);
  [DllImport("kernel32.dll", SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool ProcessIdToSessionId(
      uint processId, out uint sessionId);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool QueryFullProcessImageNameW(
      IntPtr process, uint flags, StringBuilder imageName, ref uint size);
  [DllImport("kernel32.dll", SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool GetProcessTimes(
      IntPtr process,
      out FileTimeParts creationTime,
      out FileTimeParts exitTime,
      out FileTimeParts kernelTime,
      out FileTimeParts userTime);
  [DllImport("kernel32.dll", SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool GetExitCodeProcess(
      IntPtr process, out uint exitCode);
  [DllImport("kernel32.dll", SetLastError = true)]
  [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool TerminateProcess(IntPtr process, uint exitCode);
  [DllImport("kernel32.dll", SetLastError = true)]
  private static extern uint WaitForSingleObject(
      IntPtr handle, uint milliseconds);
  [DllImport("kernel32.dll")]
  [return: MarshalAs(UnmanagedType.Bool)]
  private static extern bool CloseHandle(IntPtr handle);

  // 0 = terminated, 1 = already gone, 2 = live identity mismatch,
  // 3 = durable record does not belong to this installation.
  public static int Terminate(
      uint expectedProcessId,
      string expectedPath,
      string trustedPath,
      uint expectedSessionId,
      ulong expectedCreationTimeUtcFileTime) {
    string canonicalExpectedPath = Path.GetFullPath(expectedPath);
    string canonicalTrustedPath = Path.GetFullPath(trustedPath);
    if (!canonicalExpectedPath.Equals(
        canonicalTrustedPath, StringComparison.OrdinalIgnoreCase)) {
      return 3;
    }
    IntPtr process = OpenProcess(
        ProcessQueryLimitedInformation | ProcessTerminate | Synchronize,
        false,
        expectedProcessId);
    if (process == IntPtr.Zero) {
      int error = Marshal.GetLastWin32Error();
      if (error == 87) return 1;
      throw new Win32Exception(error);
    }
    try {
      uint exitCode;
      if (!GetExitCodeProcess(process, out exitCode)) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }
      if (exitCode != StillActive) {
        return 1;
      }
      uint liveProcessId = GetProcessId(process);
      if (liveProcessId == 0) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }
      uint liveSessionId;
      if (!ProcessIdToSessionId(liveProcessId, out liveSessionId)) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }
      var imageName = new StringBuilder(32768);
      uint imageNameSize = (uint)imageName.Capacity;
      if (!QueryFullProcessImageNameW(
          process, 0, imageName, ref imageNameSize)) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }
      FileTimeParts creationTime;
      FileTimeParts exitTime;
      FileTimeParts kernelTime;
      FileTimeParts userTime;
      if (!GetProcessTimes(
          process,
          out creationTime,
          out exitTime,
          out kernelTime,
          out userTime)) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }
      ulong liveCreationTimeUtcFileTime =
          ((ulong)creationTime.HighDateTime << 32) | creationTime.LowDateTime;
      if (liveProcessId != expectedProcessId ||
          liveSessionId != expectedSessionId ||
          !Path.GetFullPath(imageName.ToString()).Equals(
              canonicalExpectedPath,
              StringComparison.OrdinalIgnoreCase) ||
          liveCreationTimeUtcFileTime != expectedCreationTimeUtcFileTime) {
        return 2;
      }
      if (!TerminateProcess(process, 1)) {
        throw new Win32Exception(Marshal.GetLastWin32Error());
      }
      uint waitResult = WaitForSingleObject(process, 8000);
      if (waitResult == WaitObject0) return 0;
      if (waitResult == WaitTimeout) {
        throw new TimeoutException("Timed out waiting for process termination.");
      }
      throw new Win32Exception(Marshal.GetLastWin32Error());
    } finally {
      CloseHandle(process);
    }
  }
}
'@
\$result = [SsrvpnVerifiedProcessTerminator]::Terminate(
  [uint32]${record.pid},
  \$expectedPath,
  \$trustedPath,
  [uint32][Diagnostics.Process]::GetCurrentProcess().SessionId,
  [uint64]${record.creationTimeUtcFileTime})
if (\$result -eq 0 -or \$result -eq 1) { exit 0 }
if (\$result -eq 2) { exit 3 }
if (\$result -eq 3) { exit 5 }
exit 4
''';
    final result = await _runPowerShell(
      script,
      timeout: const Duration(seconds: 8),
    );
    return switch (result.exitCode) {
      0 => _VerifiedCoreTermination.terminatedOrGone,
      3 => _VerifiedCoreTermination.liveIdentityMismatch,
      5 => _VerifiedCoreTermination.wrongInstallation,
      _ => throw StateError('PowerShell 返回 ${result.exitCode}'),
    };
  }

  Future<ProcessResult> _runPowerShell(
    String script, {
    Duration timeout = const Duration(seconds: 10),
    Future<void>? cancellation,
  }) =>
      TimedProcessRunner.run(
        windowsPowerShellExecutable(),
        [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          windowsPowerShellUtf8Script(script),
        ],
        timeout: timeout,
        timeoutStderr: '电脑性能不足，请重新连接',
        cancellation: cancellation,
      );

  Future<WindowsCorePidRecord> _captureCorePidRecord(int corePid) async {
    final encodedTrustedPath = base64Encode(utf8.encode(_corePath));
    final script = '''
\$trustedPath = [Text.Encoding]::UTF8.GetString(
  [Convert]::FromBase64String('$encodedTrustedPath'))
\$process = [Diagnostics.Process]::GetProcessById([int]$corePid)
try {
  \$process.Refresh()
  if (\$process.HasExited) {
    throw 'Mihomo exited before its durable identity was captured.'
  }
  \$livePath = [IO.Path]::GetFullPath(\$process.MainModule.FileName)
  \$canonicalTrustedPath = [IO.Path]::GetFullPath(\$trustedPath)
  \$currentSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
  if (\$process.Id -ne [int]$corePid -or
      \$process.SessionId -ne \$currentSessionId -or
      -not \$livePath.Equals(
        \$canonicalTrustedPath,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Mihomo identity did not match the process started by SSRVPN.'
  }
  \$creationTime = \$process.StartTime.ToUniversalTime().ToFileTimeUtc()
  if (\$creationTime -le 0) {
    throw 'Mihomo creation time was invalid.'
  }
  [ordered]@{
    version = $windowsCorePidRecordVersion
    pid = [int]$corePid
    creationTimeUtcFileTime = \$creationTime.ToString(
      [Globalization.CultureInfo]::InvariantCulture)
    canonicalExecutablePath = \$livePath
  } | ConvertTo-Json -Compress
} finally {
  \$process.Dispose()
}
''';
    final result = await _runPowerShell(
      script,
      timeout: const Duration(seconds: 8),
    );
    if (result.exitCode != 0) {
      throw StateError('无法读取新启动 Mihomo 的完整进程身份');
    }
    final record = WindowsCorePidRecord.tryParse(
      result.stdout.toString().trim(),
    );
    if (record == null ||
        record.pid != corePid ||
        record.canonicalExecutablePath.toLowerCase() !=
            _corePath.toLowerCase()) {
      throw StateError('新启动 Mihomo 的进程身份校验失败');
    }
    return record;
  }

  // ── clang-format off: Start / Stop ──

  /// 启动核心
  @override
  Future<bool> start() => _start();

  @override
  Future<bool> startForAutomaticRecovery() => _start(automaticRecovery: true);

  Future<bool> _start({
    bool automaticRecovery = false,
    bool preserveSystemProxyRecovery = false,
  }) {
    if (!automaticRecovery) {
      _unexpectedExitRecoveryPolicy.reset();
    }
    final current = _startOperation;
    if (current != null) return current;

    final startToken = ++_startGeneration;
    _startCancellation = Completer<void>();
    final operation = _startInternal(
      startToken,
      preserveSystemProxyRecovery: preserveSystemProxyRecovery,
    );
    _startOperation = operation;
    operation.then<void>(
      (_) => _clearStartOperation(operation),
      onError: (_, __) => _clearStartOperation(operation),
    );
    return operation;
  }

  Future<bool> _startInternal(
    int startToken, {
    bool preserveSystemProxyRecovery = false,
  }) async {
    final pidCleanup = _pidCleanupOperation;
    if (pidCleanup != null) await pidCleanup;
    final exitCleanup = _exitCleanupOperation;
    if (exitCleanup != null) await exitCleanup;
    _ensureStartCurrent(startToken);
    final stopping = _stopOperation;
    if (stopping != null) await stopping;
    _ensureStartCurrent(startToken);
    setLastStartError(null);
    _tunElevationRelaunchPending = false;

    if (_startupDisabledReason != null) {
      setLastStartError(_startupDisabledReason);
      log(_startupDisabledReason!);
      return false;
    }
    if (_corePath.isEmpty || configDir.isEmpty || configPath.isEmpty) {
      setLastStartError('Mihomo service is not initialized');
      log(lastStartError!);
      return false;
    }

    try {
      if (isRunning) {
        try {
          if (await healthCheck()) return true;
        } catch (_) {}
        _ensureStartCurrent(startToken);
        final stoppedSafely = await _stopInternal();
        _ensureStartCurrent(startToken);
        if (!stoppedSafely) {
          setLastStartError(_lastStopError ?? '现有 Mihomo 连接无法安全停止，已拒绝启动新的核心');
          log('❌ $lastStartError');
          return false;
        }
      }

      if (_coreProcess != null) {
        log('检测到尚未确认退出的 Mihomo，正在安全清理...');
        final stoppedSafely = await _stopInternal();
        _ensureStartCurrent(startToken);
        if (!stoppedSafely || _coreProcess != null) {
          setLastStartError(_lastStopError ?? '上一个 Mihomo 进程尚未退出，已拒绝启动新的核心');
          log('❌ $lastStartError');
          return false;
        }
      }

      if (_tunTeardownGate.shouldProbeBeforeStart(
        enableTun: settings.enableTun,
      )) {
        if (!await _waitForTunTeardown()) {
          _ensureStartCurrent(startToken);
          setLastStartError(_tunResidualProbeError);
          log('❌ $lastStartError');
          return false;
        }
        _ensureStartCurrent(startToken);
      }

      final startupWatch = Stopwatch()..start();
      log('🚀 启动 Mihomo...');

      // 检查核心文件
      if (!File(_corePath).existsSync()) {
        log('❌ 核心文件不存在: $_corePath');
        log('请下载 mihomo-windows-amd64 并重命名为 mihomo.exe 放到应用目录');
        setLastStartError('找不到 mihomo.exe，文件可能未完整解压或被安全软件隔离');
        return false;
      }

      if (!File(configPath).existsSync()) {
        log('❌ 配置文件不存在: $configPath');
        setLastStartError('找不到生成的 Mihomo 配置文件');
        return false;
      }

      if (settings.enableTun) {
        final isAdministrator = await _awaitStartOperation(
          _isAdministrator(cancellation: _startCancellation?.future),
          startToken,
        );
        _ensureStartCurrent(startToken);
        if (isAdministrator != true) {
          WindowsTunElevationRequestResult? elevationRequest;
          if (isAdministrator == false) {
            elevationRequest = await _awaitStartOperation(
              _tunElevationService.requestRelaunch(),
              startToken,
            );
            _ensureStartCurrent(startToken);
          }
          if (elevationRequest == WindowsTunElevationRequestResult.launched) {
            _tunElevationRelaunchPending = true;
          }
          setLastStartError(switch (elevationRequest) {
            WindowsTunElevationRequestResult.launched =>
              'TUN 模式需要管理员权限，SSRVPN 正在自动重启并继续连接',
            WindowsTunElevationRequestResult.cancelled => '已取消管理员授权，TUN 模式未启动',
            WindowsTunElevationRequestResult.standardUser =>
              '当前 Windows 账户不能直接提升为管理员；TUN 模式未启动，请使用管理员账户运行 SSRVPN',
            WindowsTunElevationRequestResult.failed =>
              '无法打开管理员授权窗口，TUN 模式未启动，请手动以管理员身份运行 SSRVPN',
            null => '无法确认管理员权限，TUN 模式已安全中止，请重新以管理员身份运行 SSRVPN',
          });
          log('❌ $lastStartError');
          return false;
        }
      }

      // 创建 tmp 目录
      final tmpDir = '$configDir${Platform.pathSeparator}tmp';
      await Directory(tmpDir).create(recursive: true);
      _ensureStartCurrent(startToken);
      final environment = {'TMPDIR': tmpDir, 'TMP': tmpDir, 'TEMP': tmpDir};

      if (!await _validateConfig(environment)) {
        setLastStartError(lastStartError ?? 'Mihomo 配置校验失败，请打开运行日志查看具体配置错误');
        return false;
      }
      _ensureStartCurrent(startToken);
      final pidFile = File('$configDir${Platform.pathSeparator}mihomo.pid');
      final pidFileType = await FileSystemEntity.type(
        pidFile.path,
        followLinks: false,
      );
      if (_corePidRecord != null ||
          pidFileType != FileSystemEntityType.notFound) {
        setLastStartError('检测到尚未安全清理的 Mihomo 进程身份记录，已拒绝启动新的核心');
        log('❌ $lastStartError');
        return false;
      }

      // 启动 mihomo 子进程（运行数据位于安装版数据目录）
      if (_coreProcess != null) {
        setLastStartError('上一个 Mihomo 进程尚未退出，已拒绝启动新的核心');
        log('❌ $lastStartError');
        await _cleanupFailedStart();
        return false;
      }
      if (settings.enableTun &&
          !await _awaitStartOperation(
            _proxyService.isLauncherGuardianReady(
              cancellation: _startCancellation?.future,
            ),
            startToken,
          )) {
        _ensureStartCurrent(startToken);
        setLastStartError(
          '独立崩溃保护进程未就绪，TUN 模式已安全中止；'
          '请通过 ssrvpn_windows.exe 启动或重试',
        );
        log('❌ $lastStartError');
        return false;
      }
      final processStartWatch = Stopwatch()..start();
      final startedWithTun = settings.enableTun;
      if (startedWithTun) {
        final baselineProbe = _networkInterfaceIdentityProbeOverride;
        _tunInterfacesBeforeStart = await _awaitStartOperation(
          baselineProbe?.call() ??
              probeWindowsNetworkInterfaceIdentities(
                cancellation: _startCancellation?.future,
              ),
          startToken,
        );
      } else {
        _tunInterfacesBeforeStart = const <WindowsTunInterfaceIdentity>{};
      }
      _ensureStartCurrent(startToken);
      if (startedWithTun && !await _armTunTeardownGate()) {
        _tunInterfacesBeforeStart = const <WindowsTunInterfaceIdentity>{};
        _ensureStartCurrent(startToken);
        setLastStartError('无法持久化 TUN 清理状态，已在启动 Mihomo 前安全中止');
        log('❌ $lastStartError');
        return false;
      }
      _ensureStartCurrent(startToken);
      final coreSpawnStartedAtUtcFileTime = currentWindowsUtcFileTime();
      final startedProcess = await Process.start(
        _corePath,
        ['-d', configDir, '-f', configPath],
        mode: ProcessStartMode.normal,
        includeParentEnvironment: true,
        environment: environment,
      );
      final coreSpawnReturnedAtUtcFileTime = currentWindowsUtcFileTime();
      log('Mihomo 进程已创建，耗时 ${processStartWatch.elapsedMilliseconds}ms');
      _coreProcess = startedProcess;
      _coreUsesTun = startedWithTun;
      final identityEstablishment = WindowsCoreIdentityEstablishment(
        startedProcess,
        spawnStartedAtUtcFileTime: coreSpawnStartedAtUtcFileTime,
        spawnReturnedAtUtcFileTime: coreSpawnReturnedAtUtcFileTime,
      );
      _coreIdentityEstablishment = identityEstablishment;
      final startedPidRecord = await identityEstablishment.establish(
        capture: _captureCorePidRecord,
        persist: _writeCorePid,
        ensureStartCurrent: () => _ensureStartCurrent(startToken),
      );
      _corePidRecord = startedPidRecord;
      _coreIdentityEstablishment = null;
      int? startupExitCode;
      final startupOutput = <String>[];

      // 监听子进程输出
      startedProcess.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
        final message = line.trim();
        if (message.isEmpty) return;
        startupOutput.add(message);
        if (startupOutput.length > 30) startupOutput.removeAt(0);
        log('[mihomo] $message');
      });
      startedProcess.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen((line) {
        final message = line.trim();
        if (message.isEmpty) return;
        startupOutput.add(message);
        if (startupOutput.length > 30) startupOutput.removeAt(0);
        log('[mihomo stderr] $message');
      });

      // 监听子进程退出
      startedProcess.exitCode.then((code) {
        startupExitCode = code;
        if (!isUnexpectedCoreExit(
          ownsProcess: identical(_coreProcess, startedProcess),
          stoppingCore: _stoppingCore,
          stopInProgress: _stopOperation != null,
        )) {
          return;
        }
        final wasRunning = isRunning;

        log('❌ Mihomo 进程已退出，退出码: $code');
        final recoveryListenerWasActive = _proxyRecoveryListenerActive;
        _proxyRecoveryListenerActive = false;
        final tunInterfaces =
            startedWithTun ? _captureTunInterfaceIdentities() : null;
        if (tunInterfaces != null) {
          _tunTeardownGate.markPending();
        }
        if (recoveryListenerWasActive) {
          log('⚠️ 系统代理保护监听已退出，重新执行安全恢复');
        }
        final cleanup = _deleteCorePid(expectedRecord: startedPidRecord)
            .then<void>((recordDeleted) {
          final ownsExitedProcess = identical(_coreProcess, startedProcess);
          final ownsPidRecord = identical(_corePidRecord, startedPidRecord);
          final exitStillUnexpected = isUnexpectedCoreExit(
            ownsProcess: ownsExitedProcess,
            stoppingCore: _stoppingCore,
            stopInProgress: _stopOperation != null,
          );
          final memoryCleanup = classifyExitedCoreMemoryCleanup(
            ownsExitedProcess: ownsExitedProcess,
            ownsPidRecord: ownsPidRecord,
            pidRecordDeleted: recordDeleted,
            wasRunning: wasRunning,
          );
          if (memoryCleanup.releaseProcessReference) {
            _corePidRecord = null;
            _coreProcess = null;
            if (memoryCleanup.clearTunOwnership) {
              _coreUsesTun = false;
            }
          }
          if (!exitStillUnexpected) {
            return;
          }
          if (isRunning) {
            final restartGeneration = memoryCleanup.releaseProcessReference
                ? captureAutomaticRestartIntent()
                : null;
            if (!memoryCleanup.releaseProcessReference) {
              setLastStartError('Mihomo 进程身份清理无法安全完成，已阻止自动重启');
              notifyRuntimeNotice(
                '连接已断开；检测到进程身份记录异常，为避免误清理其他进程，'
                '本次不会自动重连。请重新安装或联系支持。',
              );
            }
            if (memoryCleanup.clearConnectionIntent) {
              markConnectionLost();
            } else {
              setRunning(false);
              notifyStatusChanged();
            }
            stopStatusMonitor();
            _scheduleUnexpectedExitRecovery(
              restartGeneration,
              code,
              tunInterfaces,
            );
          }
        });
        _pidCleanupOperation = cleanup;
        cleanup.whenComplete(() {
          if (identical(_pidCleanupOperation, cleanup)) {
            _pidCleanupOperation = null;
          }
        });
      });

      // 慢速磁盘或首次启动可能超过 2 秒，轮询等待 API 就绪。
      var healthy = false;
      var tunIdentityPersisted = !startedWithTun;
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline) && startupExitCode == null) {
        _ensureStartCurrent(startToken);
        if (!tunIdentityPersisted) {
          tunIdentityPersisted = await _persistTunInterfaceIdentities();
          _ensureStartCurrent(startToken);
        }
        healthy = await healthCheck();
        _ensureStartCurrent(startToken);
        if (healthy) break;
        await Future.delayed(const Duration(milliseconds: 250));
      }

      if (healthy) {
        _ensureStartCurrent(startToken);
        // 设置系统代理（非 TUN 模式时）
        if (!settings.enableTun && !preserveSystemProxyRecovery) {
          final proxyWatch = Stopwatch()..start();
          final proxySet = await _proxyService.setSystemProxy(
            '127.0.0.1',
            settings.proxyPort,
            cancellation: _startCancellation?.future,
          );
          _ensureStartCurrent(startToken);
          if (proxySet) {
            log('✅ 系统代理已设置，耗时 ${proxyWatch.elapsedMilliseconds}ms');
          } else {
            setLastStartError(_proxyService.lastError ?? 'Windows 系统代理设置失败');
            log('❌ $lastStartError，连接已取消');
            await _cleanupFailedStart();
            return false;
          }
        }

        final processStillHealthy = await healthCheck();
        _ensureStartCurrent(startToken);
        final canCommitRunning = identical(_coreProcess, startedProcess) &&
            startupExitCode == null &&
            processStillHealthy;
        if (!canCommitRunning) {
          setLastStartError(
            startupExitCode == null
                ? 'Mihomo 在系统代理设置期间失去响应'
                : 'Mihomo 在系统代理设置期间退出（退出码 $startupExitCode）',
          );
          log('❌ $lastStartError');
          await _cleanupFailedStart();
          return false;
        }
        if (startedWithTun &&
            !tunIdentityPersisted &&
            !await _persistTunInterfaceIdentities()) {
          _ensureStartCurrent(startToken);
          log(
            '⚠️ TUN 已启动，但 Windows 未暴露可持久化的网卡身份；'
            '已保留启动前基线，本项仅记录诊断告警',
          );
        }

        _proxyRecoveryListenerActive = preserveSystemProxyRecovery;
        setRunning(true);
        resetHealthCheckFailures();
        log('✅ Mihomo API 就绪，耗时 ${startupWatch.elapsedMilliseconds}ms');

        notifyStatusChanged();
        startStatusMonitor();
        return true;
      } else {
        if (startupExitCode != null) {
          final detail = startupOutput.isEmpty ? '' : ': ${startupOutput.last}';
          setLastStartError('Mihomo 提前退出（退出码 $startupExitCode）$detail');
          log('❌ 核心启动失败: $lastStartError');
        } else {
          setLastStartError(
            settings.enableTun
                ? 'TUN 网卡或路由未能启用，请检查管理员权限、驱动或同名虚拟网卡冲突'
                : '电脑性能不足，请重新连接',
          );
          log('❌ 核心启动后健康检查失败: $lastStartError');
        }
        await _cleanupFailedStart();
        return false;
      }
    } on _DesktopStartCancelled {
      setLastStartError('连接已取消');
      log('Mihomo 启动已取消');
      await _cleanupFailedStart();
      return false;
    } catch (e, stack) {
      setLastStartError(_friendlyStartException(e));
      log('❌ 启动异常: $e');
      log('堆栈: $stack');
      await _cleanupFailedStart();
      return false;
    }
  }

  Future<void> _cleanupFailedStart() async {
    final startError = lastStartError?.trim();
    try {
      if (await _stopInternal()) return;
    } catch (error) {
      _lastStopError = '启动失败后无法确认 Mihomo 已停止: $error';
    }
    final cleanupError = _lastStopError ?? '启动失败后无法确认 Mihomo 已安全停止';
    if (startError == null || startError.isEmpty) {
      setLastStartError(cleanupError);
    } else if (!startError.contains(cleanupError)) {
      setLastStartError('$startError；$cleanupError');
    }
    log('❌ 启动失败后的清理未完成: $cleanupError');
  }

  // ── Stop ──

  @override
  void interruptPendingStart() {
    _startGeneration++;
    final cancellation = _startCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
  }

  /// 停止核心
  @override
  Future<void> stop() {
    interruptPendingStart();
    final current = _stopOperation;
    if (current != null) return current;

    final operation = _stopAfterStart();
    _stopOperation = operation;
    operation.then<void>(
      (_) => _clearStopOperation(operation),
      onError: (_, __) => _clearStopOperation(operation),
    );
    return operation;
  }

  Future<void> _stopAfterStart() async {
    final starting = _startOperation;
    if (starting != null) await starting;
    final stoppedSafely = await _stopInternal();
    if (!stoppedSafely) {
      throw StateError(
        _lastStopError ?? _proxyService.lastError ?? 'Windows 系统代理恢复失败，请再次尝试断开',
      );
    }
  }

  Future<bool> _stopInternal() async {
    final needsTunTeardown = _coreUsesTun || _tunTeardownGate.pending;
    _lastStopError = null;
    final pidCleanup = _pidCleanupOperation;
    if (pidCleanup != null) await pidCleanup;
    final exitCleanup = _exitCleanupOperation;
    if (exitCleanup != null) await exitCleanup;
    final tunInterfaces = needsTunTeardown
        ? await _captureTunInterfaceIdentities()
        : const <WindowsTunInterfaceIdentity>{};
    stopStatusMonitor();
    resetHealthCheckFailures();

    // Restore Windows networking while the local proxy is still alive. Keep
    // the core only while Windows may still point at its local endpoint; once
    // that endpoint is safe, a pending journal cleanup must not leave the UI
    // connected to a core that the user asked to stop.
    final journalTerminal = await _proxyService.clearSystemProxy();
    final recoveryDisposition = classifyProxyRecoveryDisposition(
      journalTerminal: journalTerminal,
      endpointSafeWithPendingRecovery:
          _proxyService.endpointSafeWithPendingRecovery,
    );
    if (recoveryDisposition ==
        ProxyRecoveryDisposition.endpointMayStillBeOwned) {
      _lastStopError = _proxyService.lastError ?? 'Windows 系统代理恢复失败，请再次尝试断开';
      if (_proxyService.lastError != null) {
        log('⚠️ ${_proxyService.lastError}');
      }
      if (isRunning) startStatusMonitor();
      notifyStatusChanged();
      return false;
    }
    if (recoveryDisposition ==
        ProxyRecoveryDisposition.endpointSafeWithPendingJournal) {
      final warning = _proxyService.lastError ?? 'SSRVPN 代理端点已安全释放，但恢复日志仍待清理';
      log('⚠️ $warning');
      notifyRuntimeNotice(
        '连接已安全断开，但 Windows 代理恢复日志仍待清理；请保持 SSRVPN '
        '打开并使用“诊断”重试，清理完成前不要强制退出。',
      );
    }
    if (_proxyService.recoveryPending && _proxyService.lastError != null) {
      log('⚠️ ${_proxyService.lastError}');
    }
    _proxyRecoveryListenerActive = false;

    // The proxy endpoint is already safe, so the UI must be disconnected even
    // if an orphaned core later refuses to exit. The tracked process still
    // blocks a new start until cleanup is confirmed.
    setRunning(false);
    notifyStatusChanged();

    final coreProcess = _coreProcess;
    final identityEstablishment = _coreIdentityEstablishment;
    final pendingIdentity = coreProcess != null &&
            identityEstablishment != null &&
            identityEstablishment.ownsProcess(coreProcess)
        ? identityEstablishment.capturedIdentity
        : null;
    final expectedPidRecord = _corePidRecord ?? pendingIdentity;
    if (coreProcess != null) {
      _stoppingCore = true;
      try {
        if (expectedPidRecord == null) {
          if (identityEstablishment == null ||
              !identityEstablishment.ownsUnidentifiedProcess(coreProcess)) {
            _lastStopError = '缺少 Mihomo 完整进程身份，且无法确认原始启动句柄，已拒绝终止';
            log('❌ $_lastStopError');
            return false;
          }
          final stopped =
              await identityEstablishment.terminateUnidentifiedProcess(
            coreProcess,
            terminate: terminateCoreProcess,
          );
          if (!stopped) {
            _lastStopError = '新启动的 Mihomo 在强制停止后仍未退出';
            log('❌ $_lastStopError');
            return false;
          }
        } else {
          final disposition = await _terminateVerifiedCore(expectedPidRecord);
          if (disposition == _VerifiedCoreTermination.wrongInstallation) {
            _lastStopError = 'Mihomo 进程身份不属于当前安装，已拒绝终止';
            log('❌ $_lastStopError');
            return false;
          }
          if (disposition == _VerifiedCoreTermination.liveIdentityMismatch) {
            log('Mihomo 原进程已退出；检测到 PID 被复用，未终止新进程');
          }
        }
      } catch (e) {
        _lastStopError = expectedPidRecord == null
            ? '无法通过原始启动句柄确认 Mihomo 已停止: $e'
            : '无法按完整进程身份确认 Mihomo 已停止: $e';
        log('❌ $_lastStopError');
        return false;
      } finally {
        _stoppingCore = false;
      }
      _coreProcess = null;
      if (identityEstablishment?.ownsProcess(coreProcess) ?? false) {
        _coreIdentityEstablishment = null;
      }
    }
    if (_coreProcess == null) _coreUsesTun = false;
    var pidRecordCleaned = true;
    if (expectedPidRecord != null) {
      pidRecordCleaned = await _deleteCorePid(
        expectedRecord: expectedPidRecord,
      );
      if (pidRecordCleaned && identical(_corePidRecord, expectedPidRecord)) {
        _corePidRecord = null;
      }
    } else {
      final pidFile = File('$configDir${Platform.pathSeparator}mihomo.pid');
      final pidFileType = await FileSystemEntity.type(
        pidFile.path,
        followLinks: false,
      );
      pidRecordCleaned = pidFileType == FileSystemEntityType.notFound;
      if (!pidRecordCleaned) {
        log('存在无法归属的核心进程身份记录，已保留');
      }
    }
    if (!pidRecordCleaned) {
      _lastStopError = 'Mihomo 已停止，但进程身份记录无法安全删除；已阻止再次连接';
    }

    if (needsTunTeardown) {
      _tunTeardownGate.markPending(tunInterfaces, _tunInterfacesBeforeStart);
      if (!await _waitForTunTeardown()) {
        _lastStopError = _tunTeardownTimeoutError;
        setRunning(false);
        notifyStatusChanged();
        log('❌ $_lastStopError');
        return false;
      }
    }
    _tunInterfacesBeforeStart = const <WindowsTunInterfaceIdentity>{};
    if (!pidRecordCleaned) {
      log('❌ $_lastStopError');
      return false;
    }

    setRunning(false);
    notifyStatusChanged();
    log('核心已停止');
    return true;
  }

  void _ensureStartCurrent(int startToken) {
    if (startToken != _startGeneration) throw _DesktopStartCancelled();
  }

  Future<void> _writeCorePid(WindowsCorePidRecord record) async {
    final file = File('$configDir${Platform.pathSeparator}mihomo.pid');
    final existingType = await FileSystemEntity.type(
      file.path,
      followLinks: false,
    );
    if (existingType != FileSystemEntityType.notFound) {
      throw StateError('已有 Mihomo 进程身份记录，已拒绝覆盖');
    }

    final temp = File(
      '${file.path}.${record.pid}.'
      '${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      final tempType = await FileSystemEntity.type(
        temp.path,
        followLinks: false,
      );
      if (tempType != FileSystemEntityType.notFound) {
        throw StateError('Mihomo 进程身份临时记录已存在');
      }
      await temp.writeAsString(record.encode(), flush: true);
      final publishTargetType = await FileSystemEntity.type(
        file.path,
        followLinks: false,
      );
      if (publishTargetType != FileSystemEntityType.notFound) {
        throw StateError('Mihomo 进程身份记录在写入期间出现，已拒绝覆盖');
      }
      await temp.rename(file.path);
      final persisted = WindowsCorePidRecord.tryParse(
        await file.readAsString(),
      );
      if (persisted == null || !persisted.hasSameIdentity(record)) {
        throw StateError('Mihomo 进程身份记录写入后校验失败');
      }
    } finally {
      final tempType = await FileSystemEntity.type(
        temp.path,
        followLinks: false,
      );
      if (tempType == FileSystemEntityType.file) {
        try {
          await temp.delete();
        } catch (error) {
          log('删除核心身份临时文件失败: $error');
        }
      }
    }
  }

  Future<bool> _deleteCorePid({
    required WindowsCorePidRecord expectedRecord,
  }) async {
    final file = File('$configDir${Platform.pathSeparator}mihomo.pid');
    try {
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      if (type == FileSystemEntityType.notFound) return true;
      if (type != FileSystemEntityType.file) {
        log('核心进程身份记录不是普通文件，已保留');
        return false;
      }
      final length = await file.length();
      if (length <= 0 || length > maxWindowsCorePidRecordBytes) {
        log('核心进程身份记录大小异常，已保留');
        return false;
      }
      final current = WindowsCorePidRecord.tryParse(await file.readAsString());
      if (current == null || !current.hasSameIdentity(expectedRecord)) {
        log('核心进程身份记录无法验证或已发生变化，已保留');
        return false;
      }
      await file.delete();
      return await FileSystemEntity.type(file.path, followLinks: false) ==
          FileSystemEntityType.notFound;
    } catch (error) {
      log('删除核心进程身份记录失败，已保留: $error');
      return false;
    }
  }

  void _scheduleUnexpectedExitRecovery(
    int? generation,
    int exitCode,
    Future<Set<WindowsTunInterfaceIdentity>>? tunInterfaces,
  ) {
    final cleanup = _prepareUnexpectedExitProxyCleanup(
      generation,
      usedSystemProxy: tunInterfaces == null,
    );
    final operation = cleanup.then<void>((_) {});
    _exitCleanupOperation = operation;
    cleanup.then((proxyCleanup) {
      if (identical(_exitCleanupOperation, operation)) {
        _exitCleanupOperation = null;
      }
      unawaited(
        _recoverFromUnexpectedExit(
          generation,
          exitCode,
          proxyCleanup,
          tunInterfaces,
        ),
      );
    });
  }

  Future<DesktopUnexpectedExitProxyCleanupResult>
      _prepareUnexpectedExitProxyCleanup(
    int? generation, {
    required bool usedSystemProxy,
  }) async {
    SystemProxyOwnershipStatus? ownershipBeforeClear;
    if (usedSystemProxy) {
      try {
        ownershipBeforeClear = await inspectSystemProxyOwnership();
      } catch (error) {
        ownershipBeforeClear = SystemProxyOwnershipStatus.unavailable;
        log('⚠️ 核心异常退出前无法确认系统代理所有权: $error');
      }
      if (ownershipBeforeClear != SystemProxyOwnershipStatus.owned &&
          generation != null &&
          isConnectionIntentCurrent(generation, connected: true)) {
        // Cleanup/discard remains allowed, but invalidate automatic restart
        // before the asynchronous registry transaction can race with it.
        markConnectionLost();
      }
    }

    final proxyCleared = await retryUnexpectedExitSystemProxyRecovery(
      clearProxy: clearSystemProxyAfterUnexpectedExit,
      onAttemptFailed: (attempt, totalAttempts) {
        log('⚠️ 核心退出后的系统代理恢复未完成 ($attempt/$totalAttempts)');
      },
    );
    final ownershipChangedDuringClear =
        usedSystemProxy && systemProxyOwnershipChangedSinceLastAcquisition;
    if (ownershipChangedDuringClear &&
        generation != null &&
        isConnectionIntentCurrent(generation, connected: true)) {
      markConnectionLost();
    }
    return DesktopUnexpectedExitProxyCleanupResult(
      proxyCleared: proxyCleared,
      ownershipBeforeClear: ownershipBeforeClear,
      ownershipChangedDuringClear: ownershipChangedDuringClear,
    );
  }

  @protected
  Future<bool> clearSystemProxyAfterUnexpectedExit() async {
    try {
      final cleared = await _proxyService.clearSystemProxy();
      if (_proxyService.lastError != null &&
          (!cleared || _proxyService.recoveryPending)) {
        log('⚠️ ${_proxyService.lastError}');
      }
      return cleared;
    } catch (error) {
      log('⚠️ 核心异常退出后清理系统代理失败: $error');
      return false;
    }
  }

  Future<void> _recoverFromUnexpectedExit(
    int? generation,
    int exitCode,
    DesktopUnexpectedExitProxyCleanupResult proxyCleanup,
    Future<Set<WindowsTunInterfaceIdentity>>? tunInterfaces,
  ) async {
    final proxyCleared = proxyCleanup.proxyCleared;
    if (tunInterfaces != null) {
      _tunTeardownGate.markPending(await tunInterfaces);
    }
    if (proxyCleanup.hasUnsafeSystemProxyOwnership) {
      final changedDuringClear = proxyCleanup.ownershipChangedDuringClear;
      final externallyChanged = proxyCleanup.ownershipBeforeClear ==
          SystemProxyOwnershipStatus.externallyChanged;
      notifyRuntimeNotice(
        proxyCleared
            ? (changedDuringClear
                ? '核心异常退出；系统代理在清理期间发生变化，SSRVPN '
                    '已取消自动重连，不会重新接管当前代理。'
                : externallyChanged
                    ? '核心异常退出；检测到系统代理已由其他程序接管，SSRVPN 已清理自身恢复状态并取消自动重连，未覆盖当前代理。'
                    : '核心异常退出；此前无法确认系统代理所有权，SSRVPN 已完成清理并取消自动重连，不会重新接管代理。')
            : '核心异常退出；已取消自动重连，但系统代理恢复状态清理无法确认。'
                '请在诊断页检查并重试断开，SSRVPN 不会重新接管代理。',
      );
      return;
    }
    final hasRecoveryIntent = hasActiveUnexpectedExitRecoveryIntent(
      generation,
      (value) => isConnectionIntentCurrent(value, connected: true),
    );
    if (!hasRecoveryIntent) {
      if (!proxyCleared) await clearSystemProxyAfterUnexpectedExit();
      return;
    }
    if (!proxyCleared) {
      // A stop may have been requested while the bounded restore was running.
      // Let it finish first: a successful stop makes the endpoint safe, while
      // a failed stop still needs the listener fallback below.
      final stopping = _stopOperation;
      if (stopping != null) {
        try {
          await stopping;
        } catch (_) {}
        _clearStopOperation(stopping);
        if (await clearSystemProxyAfterUnexpectedExit()) return;
      }

      final recoveryReason = _proxyService.lastError ?? '无法恢复 Windows 系统代理旧状态';
      final recoveryDisposition = classifyProxyRecoveryDisposition(
        journalTerminal: false,
        endpointSafeWithPendingRecovery:
            _proxyService.endpointSafeWithPendingRecovery,
      );
      if (recoveryDisposition ==
          ProxyRecoveryDisposition.endpointSafeWithPendingJournal) {
        setLastStartError(recoveryReason);
        markConnectionLost();
        notifyRuntimeNotice(
          '连接已安全断开；Windows 代理端点已释放，但恢复日志仍待清理。'
          '请保持 SSRVPN 打开并使用“诊断”重试，清理完成前不要强制退出。',
        );
        return;
      }
      notifyRuntimeNotice('系统代理恢复未完成，正在恢复本地保护监听…');
      final listenerRestored = await _start(
        automaticRecovery: true,
        preserveSystemProxyRecovery: true,
      );
      if (listenerRestored && isRunning) {
        setLastStartError(recoveryReason);
        notifyRuntimeNotice(
          '连接处于保护模式：Mihomo 本地代理监听已恢复，但 Windows '
          '系统代理旧状态仍未恢复。为避免死代理，SSRVPN 将保持运行；'
          '请使用“诊断”重试，恢复前不要强制退出。',
        );
        return;
      }

      final listenerReason = lastStartError ?? 'Mihomo 本地代理监听未能重新启动';
      markConnectionLost();
      notifyRuntimeNotice(
        '紧急：系统代理恢复失败，本地保护监听也未能启动（$listenerReason）。'
        '请保持 SSRVPN 打开并立即使用“诊断”重试恢复。',
      );
      return;
    }
    if (!hasActiveUnexpectedExitRecoveryIntent(
      generation,
      (value) => isConnectionIntentCurrent(value, connected: true),
    )) {
      return;
    }
    if (tunInterfaces != null && !await _waitForTunTeardown()) {
      setLastStartError(_tunTeardownTimeoutError);
      markConnectionLost();
      notifyRuntimeNotice('核心已退出：$_tunTeardownTimeoutError');
      return;
    }
    if (!_unexpectedExitRecoveryPolicy.tryAcquire()) {
      markConnectionLost();
      notifyRuntimeNotice('连接已断开：核心再次异常退出，自动恢复失败，请重新连接');
      return;
    }

    notifyRuntimeNotice('核心异常退出，正在自动恢复（退出码 $exitCode）');
    final restarted = await recoverDesktopConnection(generation!);

    if (!hasActiveUnexpectedExitRecoveryIntent(
      generation,
      (value) => isConnectionIntentCurrent(value, connected: true),
    )) {
      return;
    }
    if (restarted && isRunning) {
      notifyRuntimeNotice(coreAutoRecoveredRuntimeNotice);
      return;
    }

    final reason = lastStartError ?? 'Mihomo 未能重新启动';
    markConnectionLost();
    notifyRuntimeNotice('连接已断开：核心自动恢复失败（$reason），请重新连接');
  }

  @protected
  Future<void> runUnexpectedExitRecovery({
    required int? generation,
    required int exitCode,
    bool usedTun = false,
  }) async {
    final proxyCleanup = await _prepareUnexpectedExitProxyCleanup(
      generation,
      usedSystemProxy: !usedTun,
    );
    await _recoverFromUnexpectedExit(
      generation,
      exitCode,
      proxyCleanup,
      usedTun ? Future<Set<WindowsTunInterfaceIdentity>>.value(const {}) : null,
    );
  }

  void _clearStartOperation(Future<bool> operation) {
    if (identical(_startOperation, operation)) {
      _startOperation = null;
      _startCancellation = null;
    }
  }

  void _clearStopOperation(Future<void> operation) {
    if (identical(_stopOperation, operation)) {
      _stopOperation = null;
    }
  }

  // ── Admin helper ──

  Future<bool?> _isAdministrator({Future<void>? cancellation}) async {
    if (!Platform.isWindows) return null;
    try {
      final nativeResult = await _tunElevationService.queryIsElevated().timeout(
            const Duration(seconds: 2),
          );
      if (nativeResult != null) return nativeResult;
    } catch (_) {
      // Flutter unit tests and damaged native runners may not expose the
      // channel. Keep the bounded PowerShell probe as a compatibility fallback.
    }
    const script = r'''
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
''';
    try {
      final result = await _runPowerShell(
        script,
        timeout: const Duration(seconds: 5),
        cancellation: cancellation,
      );
      if (result.exitCode != 0) return null;
      final output = result.stdout.toString().trim().toLowerCase();
      if (output == 'true') return true;
      if (output == 'false') return false;
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<T> _awaitStartOperation<T>(Future<T> operation, int startToken) async {
    final cancellation = _startCancellation?.future;
    if (cancellation == null) {
      final value = await operation;
      _ensureStartCurrent(startToken);
      return value;
    }

    final completion = Completer<T>();
    operation.then<void>(
      (value) {
        if (!completion.isCompleted) completion.complete(value);
      },
      onError: (Object error, StackTrace stack) {
        if (!completion.isCompleted) completion.completeError(error, stack);
      },
    );
    cancellation.then<void>((_) {
      if (!completion.isCompleted) {
        completion.completeError(_DesktopStartCancelled());
      }
    });
    final value = await completion.future;
    _ensureStartCurrent(startToken);
    return value;
  }

  String _friendlyStartException(Object error) {
    final message = error.toString();
    final lower = message.toLowerCase();
    if (lower.contains('access is denied') ||
        lower.contains('permission denied') ||
        lower.contains('拒绝访问')) {
      return '无法执行 Mihomo，文件可能被安全软件拦截或当前目录没有执行权限';
    }
    if (lower.contains('not a valid win32') || lower.contains('不是有效的 win32')) {
      return 'Mihomo 与这台电脑的 Windows 架构不兼容，本版本仅支持 64 位 Windows';
    }
    return '启动 Mihomo 时发生异常: $message';
  }

  String? _describeWindowsExitCode(int exitCode) {
    switch (exitCode) {
      case -1073741819: // 0xC0000005
        return '访问冲突，通常是 CPU 指令集或旧版 Windows 兼容问题，也可能被安全软件注入拦截';
      case -1073741795: // 0xC000001D
        return '非法指令，当前 CPU 不支持此核心使用的指令集';
      case -1073741515: // 0xC0000135
        return '缺少运行库或依赖 DLL';
      case -1073741701: // 0xC000007B
        return '程序或依赖 DLL 的 32/64 位架构不匹配';
      default:
        return null;
    }
  }

  // ── Config validation ──

  Future<bool> _validateConfig(Map<String, String> environment) async {
    log('正在校验 Mihomo 配置...');
    final watch = Stopwatch()..start();
    try {
      final result = await TimedProcessRunner.run(
        _corePath,
        ['-t', '-d', configDir, '-f', configPath],
        includeParentEnvironment: true,
        environment: environment,
        timeout: const Duration(seconds: 40),
        cancellation: _startCancellation?.future,
        timeoutStderr: '电脑性能不足，请重新连接',
      );
      final stdout = result.stdout.toString().trim();
      final stderr = result.stderr.toString().trim();
      if (stdout.isNotEmpty) log('[配置校验] $stdout');
      if (stderr.isNotEmpty) log('[配置校验 stderr] $stderr');
      if (result.exitCode == 0) {
        log('✅ Mihomo 配置校验通过，耗时 ${watch.elapsedMilliseconds}ms');
        return true;
      }
      if (result.exitCode == 125) throw _DesktopStartCancelled();
      if (result.exitCode == 124) {
        setLastStartError('电脑性能不足，请重新连接');
        log('❌ $lastStartError');
        return false;
      }
      final reason = _describeWindowsExitCode(result.exitCode);
      final detail = stderr.isNotEmpty ? stderr : stdout;
      if (reason != null) {
        setLastStartError('Mihomo 无法在此电脑运行: $reason');
      } else if (detail.isNotEmpty) {
        setLastStartError('Mihomo 配置校验失败: $detail');
      }
      log(
        '❌ Mihomo 配置校验失败，退出码: ${result.exitCode}'
        '${reason == null ? "" : "（$reason）"}',
      );
      if (lastStartError == null) {
        setLastStartError('Mihomo 配置校验失败，请打开运行日志查看具体配置错误');
      }
      return false;
    } on _DesktopStartCancelled {
      rethrow;
    } catch (e) {
      log('❌ 无法执行 Mihomo 配置校验: $e');
      return false;
    }
  }

  // ── Core path management ──

  void setCorePath(String path) => _corePath = path;
}
