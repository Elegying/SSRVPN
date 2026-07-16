part of 'clash_service.dart';

class _DesktopStartCancelled implements Exception {}

const _unexpectedExitProxyRecoveryDelays = <Duration>[
  Duration(milliseconds: 250),
  Duration(milliseconds: 750),
  Duration(milliseconds: 1500),
];

const _tunTeardownTimeoutError = '核心已停止，但 Windows TUN 网卡未在超时前移除；'
    '为避免路由冲突，已阻止再次连接，请保持 SSRVPN 打开并重试断开';
const _tunResidualProbeError = '无法确认旧 Windows TUN 网卡和路由已清理；'
    '为避免死路由，已在启动 Mihomo 前安全中止';

enum ProxyRecoveryDisposition {
  journalTerminal,
  endpointSafeWithPendingJournal,
  endpointMayStillBeOwned,
}

ProxyRecoveryDisposition classifyProxyRecoveryDisposition({
  required bool journalTerminal,
  required bool endpointSafeWithPendingRecovery,
}) {
  if (journalTerminal) return ProxyRecoveryDisposition.journalTerminal;
  if (endpointSafeWithPendingRecovery) {
    return ProxyRecoveryDisposition.endpointSafeWithPendingJournal;
  }
  return ProxyRecoveryDisposition.endpointMayStillBeOwned;
}

/// Retries a failed proxy restore without overlapping registry transactions.
///
/// There is one initial attempt plus one attempt after every delay. The caller
/// is responsible for restoring the local proxy listener if all attempts fail.
Future<bool> retryUnexpectedExitSystemProxyRecovery({
  required Future<bool> Function() clearProxy,
  List<Duration> retryDelays = _unexpectedExitProxyRecoveryDelays,
  Future<void> Function(Duration duration)? wait,
  void Function(int attempt, int totalAttempts)? onAttemptFailed,
}) async {
  final waitFor = wait ?? (duration) => Future<void>.delayed(duration);
  final totalAttempts = retryDelays.length + 1;
  for (var attempt = 1; attempt <= totalAttempts; attempt++) {
    try {
      if (await clearProxy()) return true;
    } catch (_) {}
    onAttemptFailed?.call(attempt, totalAttempts);
    if (attempt < totalAttempts) {
      await waitFor(retryDelays[attempt - 1]);
    }
  }
  return false;
}

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
  // ── Process management ──
  Process? _coreProcess;
  Future<bool>? _startOperation;
  Completer<void>? _startCancellation;
  Future<void>? _stopOperation;
  Future<void>? _exitCleanupOperation;
  Future<void>? _pidCleanupOperation;
  WindowsTunRuntimeProbe? _tunRuntimeProbeOverride;
  WindowsTunResidualProbe? _tunResidualProbeOverride;
  final WindowsTunTeardownGate _tunTeardownGate = WindowsTunTeardownGate();
  Set<WindowsTunInterfaceIdentity> _tunInterfacesBeforeStart = const {};
  String? _lastStopError;
  int _startGeneration = 0;
  bool _coreUsesTun = false;
  bool _stoppingCore = false;
  bool _proxyRecoveryListenerActive = false;
  final CoreRecoveryPolicy _unexpectedExitRecoveryPolicy =
      CoreRecoveryPolicy(maxAttempts: 1);

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

  @override
  Future<bool> healthCheck() async {
    if (!await super.healthCheck()) return false;
    if (!settings.enableTun) return true;
    final tun = (await getConfigs())?['tun'];
    if (tun is! Map || tun['enable'] != true) {
      setLastHealthCheckError('Mihomo API 已就绪，但 TUN listener 未启用');
      return false;
    }
    final runtimeStatus = await _probeTunRuntime();
    if (runtimeStatus == WindowsTunRuntimeStatus.ready) return true;
    setLastHealthCheckError(
      switch (runtimeStatus) {
        WindowsTunRuntimeStatus.adapterMissing =>
          'Mihomo TUN listener 已启用，但 Windows TUN 网卡尚未就绪',
        WindowsTunRuntimeStatus.routeMissing =>
          'Mihomo TUN listener 已启用，但 Windows TUN 路由不完整',
        WindowsTunRuntimeStatus.probeFailed => '无法确认 Windows TUN 网卡和路由状态，已安全中止',
        WindowsTunRuntimeStatus.ready => null,
      },
    );
    return false;
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
    if (!await pidFile.exists()) return;
    final pid = int.tryParse((await pidFile.readAsString()).trim());
    if (pid == null || pid <= 1) {
      await _deleteCorePid();
      return;
    }
    final encodedPath = base64Encode(utf8.encode(_corePath));
    final script = '''
\$target = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedPath'))
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

  // 0 = terminated, 1 = already gone, 2 = identity mismatch.
  public static int Terminate(
      uint expectedProcessId, string expectedPath, uint expectedSessionId) {
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
      if (GetExitCodeProcess(process, out exitCode) && exitCode != StillActive) {
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
      if (liveProcessId != expectedProcessId ||
          liveSessionId != expectedSessionId ||
          !Path.GetFullPath(imageName.ToString()).Equals(
              Path.GetFullPath(expectedPath),
              StringComparison.OrdinalIgnoreCase)) {
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
  [uint32]$pid,
  \$target,
  [uint32][Diagnostics.Process]::GetCurrentProcess().SessionId)
if (\$result -eq 0 -or \$result -eq 1) { exit 0 }
if (\$result -eq 2) { exit 3 }
exit 4
''';
    try {
      final result = await _runPowerShell(
        script,
        timeout: const Duration(seconds: 8),
      );
      if (result.exitCode == 0 || result.exitCode == 3) {
        await _deleteCorePid();
        if (result.exitCode == 0) log('已清理遗留的 Mihomo 进程');
        return;
      }
      throw StateError('PowerShell 返回 ${result.exitCode}');
    } catch (e) {
      throw StateError('无法安全确认并清理遗留核心: $e');
    }
  }

  Future<ProcessResult> _runPowerShell(
    String script, {
    Duration timeout = const Duration(seconds: 10),
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
      );

  // ── clang-format off: Start / Stop ──

  /// 启动核心
  Future<bool> start() => _start();

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
          setLastStartError(
            _lastStopError ?? '现有 Mihomo 连接无法安全停止，已拒绝启动新的核心',
          );
          log('❌ $lastStartError');
          return false;
        }
      }

      if (_coreProcess != null) {
        log('检测到尚未确认退出的 Mihomo，正在安全清理...');
        final stoppedSafely = await _stopInternal();
        _ensureStartCurrent(startToken);
        if (!stoppedSafely || _coreProcess != null) {
          setLastStartError(
            _lastStopError ?? '上一个 Mihomo 进程尚未退出，已拒绝启动新的核心',
          );
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
        setLastStartError(
          '找不到 mihomo.exe，文件可能未完整解压或被安全软件隔离',
        );
        return false;
      }

      if (!File(configPath).existsSync()) {
        log('❌ 配置文件不存在: $configPath');
        setLastStartError('找不到生成的 Mihomo 配置文件');
        return false;
      }

      if (settings.enableTun) {
        final isAdministrator = await _isAdministrator();
        _ensureStartCurrent(startToken);
        if (isAdministrator != true) {
          setLastStartError(
            isAdministrator == false
                ? 'TUN 模式需要以管理员身份运行 SSRVPN'
                : '无法确认管理员权限，TUN 模式已安全中止，请重新以管理员身份运行 SSRVPN',
          );
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
        setLastStartError(
          lastStartError ?? 'Mihomo 配置校验失败，请打开运行日志查看具体配置错误',
        );
        return false;
      }
      _ensureStartCurrent(startToken);

      // 启动 mihomo 子进程（所有数据都在便携目录内）
      if (_coreProcess != null) {
        setLastStartError('上一个 Mihomo 进程尚未退出，已拒绝启动新的核心');
        log('❌ $lastStartError');
        await _cleanupFailedStart();
        return false;
      }
      if (settings.enableTun &&
          !await _proxyService.isLauncherGuardianReady()) {
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
      _tunInterfacesBeforeStart = startedWithTun
          ? await _observeTunInterfaceIdentities()
          : const <WindowsTunInterfaceIdentity>{};
      _ensureStartCurrent(startToken);
      if (startedWithTun && !await _armTunTeardownGate()) {
        _tunInterfacesBeforeStart = const <WindowsTunInterfaceIdentity>{};
        _ensureStartCurrent(startToken);
        setLastStartError('无法持久化 TUN 清理状态，已在启动 Mihomo 前安全中止');
        log('❌ $lastStartError');
        return false;
      }
      _ensureStartCurrent(startToken);
      final startedProcess = await Process.start(
        _corePath,
        ['-d', configDir, '-f', configPath],
        mode: ProcessStartMode.normal,
        includeParentEnvironment: true,
        environment: environment,
      );
      log('Mihomo 进程已创建，耗时 ${processStartWatch.elapsedMilliseconds}ms');
      _coreProcess = startedProcess;
      _coreUsesTun = startedWithTun;
      await _writeCorePid(startedProcess.pid);
      _ensureStartCurrent(startToken);
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
        if (!identical(_coreProcess, startedProcess) || _stoppingCore) return;

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
        final cleanup = _deleteCorePid().then<void>((_) {
          if (!identical(_coreProcess, startedProcess) || _stoppingCore) return;
          if (isRunning) {
            final restartGeneration = captureAutomaticRestartIntent();
            setRunning(false);
            notifyStatusChanged();
            stopStatusMonitor();
            _coreProcess = null;
            _coreUsesTun = false;
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
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline) && startupExitCode == null) {
        _ensureStartCurrent(startToken);
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
          );
          _ensureStartCurrent(startToken);
          if (proxySet) {
            log('✅ 系统代理已设置，耗时 ${proxyWatch.elapsedMilliseconds}ms');
          } else {
            setLastStartError(
              _proxyService.lastError ?? 'Windows 系统代理设置失败',
            );
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
        if (startedWithTun && !await _persistTunInterfaceIdentities()) {
          _ensureStartCurrent(startToken);
          setLastStartError('TUN 已启动，但无法持久化网卡身份，连接已安全取消');
          log('❌ $lastStartError');
          await _cleanupFailedStart();
          return false;
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
          setLastStartError(
            'Mihomo 提前退出（退出码 $startupExitCode）$detail',
          );
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

  /// 停止核心
  Future<void> stop() {
    _startGeneration++;
    final cancellation = _startCancellation;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
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

    final coreProcess = _coreProcess;
    if (coreProcess != null) {
      _stoppingCore = true;
      try {
        final stopped = await terminateCoreProcess(coreProcess);
        if (!stopped) {
          _lastStopError = 'Mihomo 强制停止后仍未退出，断开操作已中止';
          log('❌ $_lastStopError');
          if (isRunning) startStatusMonitor();
          notifyStatusChanged();
          return false;
        }
      } catch (e) {
        _lastStopError = '无法确认 Mihomo 已停止: $e';
        log('❌ $_lastStopError');
        if (isRunning) startStatusMonitor();
        notifyStatusChanged();
        return false;
      } finally {
        _stoppingCore = false;
      }
      _coreProcess = null;
    }
    if (_coreProcess == null) _coreUsesTun = false;
    await _deleteCorePid();

    if (needsTunTeardown) {
      _tunTeardownGate.markPending(tunInterfaces);
      if (!await _waitForTunTeardown()) {
        _lastStopError = _tunTeardownTimeoutError;
        setRunning(false);
        notifyStatusChanged();
        log('❌ $_lastStopError');
        return false;
      }
    }
    _tunInterfacesBeforeStart = const <WindowsTunInterfaceIdentity>{};

    setRunning(false);
    notifyStatusChanged();
    log('核心已停止');
    return true;
  }

  void _ensureStartCurrent(int startToken) {
    if (startToken != _startGeneration) throw _DesktopStartCancelled();
  }

  Future<void> _writeCorePid(int corePid) async {
    final file = File('$configDir${Platform.pathSeparator}mihomo.pid');
    final temp = File('${file.path}.tmp');
    await temp.writeAsString('$corePid\n', flush: true);
    await temp.rename(file.path);
  }

  Future<void> _deleteCorePid() async {
    final file = File('$configDir${Platform.pathSeparator}mihomo.pid');
    try {
      if (await file.exists()) await file.delete();
    } catch (error) {
      log('删除核心 PID 文件失败: $error');
    }
  }

  void _scheduleUnexpectedExitRecovery(
    int? generation,
    int exitCode,
    Future<Set<WindowsTunInterfaceIdentity>>? tunInterfaces,
  ) {
    final cleanup = retryUnexpectedExitSystemProxyRecovery(
      clearProxy: _clearProxyAfterUnexpectedExit,
      onAttemptFailed: (attempt, totalAttempts) {
        log('⚠️ 核心退出后的系统代理恢复未完成 ($attempt/$totalAttempts)');
      },
    );
    final operation = cleanup.then<void>((_) {});
    _exitCleanupOperation = operation;
    cleanup.then((proxyCleared) {
      if (identical(_exitCleanupOperation, operation)) {
        _exitCleanupOperation = null;
      }
      unawaited(
        _recoverFromUnexpectedExit(
          generation,
          exitCode,
          proxyCleared,
          tunInterfaces,
        ),
      );
    });
  }

  Future<bool> _clearProxyAfterUnexpectedExit() async {
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
    bool proxyCleared,
    Future<Set<WindowsTunInterfaceIdentity>>? tunInterfaces,
  ) async {
    if (tunInterfaces != null) {
      _tunTeardownGate.markPending(await tunInterfaces);
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
        if (await _clearProxyAfterUnexpectedExit()) return;
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
      notifyRuntimeNotice(
        '系统代理恢复未完成，正在恢复本地保护监听…',
      );
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
    if (generation == null ||
        !isConnectionIntentCurrent(generation, connected: true)) {
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
      notifyRuntimeNotice(
        '连接已断开：核心再次异常退出，自动恢复失败，请重新连接',
      );
      return;
    }

    notifyRuntimeNotice('核心异常退出，正在自动恢复（退出码 $exitCode）');
    final restarted = await _start(automaticRecovery: true);

    if (!isConnectionIntentCurrent(generation, connected: true)) return;
    if (restarted && isRunning) {
      notifyRuntimeNotice(coreAutoRecoveredRuntimeNotice);
      return;
    }

    final reason = lastStartError ?? 'Mihomo 未能重新启动';
    markConnectionLost();
    notifyRuntimeNotice('连接已断开：核心自动恢复失败（$reason），请重新连接');
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

  Future<WindowsTunRuntimeStatus> _probeTunRuntime() async {
    try {
      return await (_tunRuntimeProbeOverride?.call() ??
          probeWindowsTunRuntime(
            InternetAddress(AppConstants.fakeIpRange.split('/').first),
            InternetAddress(AppConstants.tunInet6Address.split('/').first),
          ));
    } catch (_) {
      return WindowsTunRuntimeStatus.probeFailed;
    }
  }

  Future<Set<WindowsTunInterfaceIdentity>> _observeTunInterfaceIdentities() =>
      probeWindowsTunInterfaceIdentities(
        InternetAddress(AppConstants.fakeIpRange.split('/').first),
        InternetAddress(AppConstants.tunInet6Address.split('/').first),
      );

  Future<Set<WindowsTunInterfaceIdentity>>
      _captureTunInterfaceIdentities() async {
    final observed = await _observeTunInterfaceIdentities();
    return selectWindowsTunInterfacesCreatedAfter(
      observed,
      _tunInterfacesBeforeStart,
    );
  }

  Future<WindowsTunResidualProbeResult> _probeTunResidual(
    Set<WindowsTunInterfaceIdentity> expectedInterfaces,
  ) async {
    try {
      return await (_tunResidualProbeOverride?.call(
            expectedInterfaces,
          ) ??
          probeWindowsTunResidual(
            expectedInterfaces: expectedInterfaces,
          ));
    } catch (_) {
      return (
        status: WindowsTunResidualStatus.probeFailed,
        interfaces: const <WindowsTunInterfaceIdentity>{},
      );
    }
  }

  Future<bool> _waitForTunTeardown() async {
    final cleared = await waitForWindowsTunTeardown(
      probe: () async {
        final result = await _probeTunResidual(
          _tunTeardownGate.interfaces,
        );
        _tunTeardownGate.observe(result);
        return result;
      },
    );
    if (cleared) {
      _tunTeardownGate.accept((
        status: WindowsTunResidualStatus.gone,
        interfaces: const <WindowsTunInterfaceIdentity>{},
      ));
      await _clearTunTeardownMarker();
    }
    return cleared;
  }

  File get _tunTeardownMarker => File(
        '$configDir${Platform.pathSeparator}tun_teardown.pending',
      );

  Future<void> _restoreTunTeardownGate() async {
    try {
      if (await _tunTeardownMarker.exists()) {
        final value = (await _tunTeardownMarker.readAsString()).trim();
        final interfaces = decodeWindowsTunTeardownMarker(value);
        if (interfaces == null) {
          throw const FormatException('invalid TUN teardown marker');
        }
        _tunTeardownGate.markPending(interfaces);
      }
    } catch (error) {
      _tunTeardownGate.markPending();
      log('⚠️ 无法读取 TUN 清理状态，后续连接将安全重试: $error');
    }
  }

  Future<bool> _armTunTeardownGate() async {
    try {
      await _tunTeardownMarker.writeAsString('pending\n', flush: true);
      _tunTeardownGate.markPending();
      return true;
    } catch (error) {
      log('❌ 无法写入 TUN 清理状态: $error');
      return false;
    }
  }

  Future<bool> _persistTunInterfaceIdentities() async {
    final interfaces = await _captureTunInterfaceIdentities();
    if (interfaces.isEmpty) return false;
    try {
      await _tunTeardownMarker.writeAsString(
        encodeWindowsTunTeardownMarker(interfaces),
        flush: true,
      );
      _tunTeardownGate.markPending(interfaces);
      return true;
    } catch (error) {
      log('❌ 无法写入 TUN 网卡身份: $error');
      return false;
    }
  }

  Future<void> _clearTunTeardownMarker() async {
    try {
      if (await _tunTeardownMarker.exists()) {
        await _tunTeardownMarker.delete();
      }
    } catch (error) {
      log('⚠️ TUN 已清理，但无法删除持久状态: $error');
    }
  }

  // ── Admin helper ──

  Future<bool?> _isAdministrator() async {
    if (!Platform.isWindows) return null;
    const script = r'''
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
''';
    try {
      final result = await _runPowerShell(
        script,
        timeout: const Duration(seconds: 5),
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
