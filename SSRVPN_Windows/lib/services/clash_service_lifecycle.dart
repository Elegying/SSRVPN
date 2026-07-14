part of 'clash_service.dart';

class _DesktopStartCancelled implements Exception {}

mixin _WindowsCoreLifecycle on ClashServiceBase {
  // ── Process management ──
  Process? _coreProcess;
  Future<bool>? _startOperation;
  Completer<void>? _startCancellation;
  Future<void>? _stopOperation;
  Future<void>? _exitCleanupOperation;
  int _startGeneration = 0;
  bool _stoppingCore = false;
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
\$process = Get-CimInstance Win32_Process -Filter "ProcessId=$pid"
if (-not \$process) { exit 0 }
if (-not \$process.ExecutablePath -or
    -not \$process.ExecutablePath.Equals(
      \$target, [System.StringComparison]::OrdinalIgnoreCase)) { exit 3 }
Stop-Process -Id $pid -Force -ErrorAction Stop
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

  Future<bool> _start({bool automaticRecovery = false}) {
    if (!automaticRecovery) {
      _unexpectedExitRecoveryPolicy.reset();
    }
    final current = _startOperation;
    if (current != null) return current;

    final startToken = ++_startGeneration;
    _startCancellation = Completer<void>();
    final operation = _startInternal(startToken);
    _startOperation = operation;
    operation.then<void>(
      (_) => _clearStartOperation(operation),
      onError: (_, __) => _clearStartOperation(operation),
    );
    return operation;
  }

  Future<bool> _startInternal(int startToken) async {
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

    if (isRunning) {
      try {
        if (await healthCheck()) return true;
      } catch (_) {}
      _ensureStartCurrent(startToken);
      setRunning(false);
      stopStatusMonitor();
    }

    try {
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
        if (isAdministrator == false) {
          setLastStartError('TUN 模式需要以管理员身份运行 SSRVPN');
          log('❌ $lastStartError');
          return false;
        }
        if (isAdministrator == null) {
          log('⚠️ 无法确认管理员权限，将继续尝试启动 TUN 模式');
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
      final processStartWatch = Stopwatch()..start();
      final startedProcess = await Process.start(
        _corePath,
        ['-d', configDir, '-f', configPath],
        mode: ProcessStartMode.normal,
        includeParentEnvironment: true,
        environment: environment,
      );
      log('Mihomo 进程已创建，耗时 ${processStartWatch.elapsedMilliseconds}ms');
      _coreProcess = startedProcess;
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
        unawaited(_deleteCorePid());
        if (isRunning) {
          final restartGeneration = captureAutomaticRestartIntent();
          setRunning(false);
          notifyStatusChanged();
          stopStatusMonitor();
          _coreProcess = null;
          _scheduleUnexpectedExitRecovery(restartGeneration, code);
        }
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
        if (!settings.enableTun) {
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
            await _stopInternal();
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
          await _stopInternal();
          return false;
        }

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
          setLastStartError('电脑性能不足，请重新连接');
          log('❌ 核心启动后健康检查失败: Mihomo API 未在 15 秒内就绪');
        }
        await _stopInternal();
        return false;
      }
    } on _DesktopStartCancelled {
      setLastStartError('连接已取消');
      log('Mihomo 启动已取消');
      await _stopInternal();
      return false;
    } catch (e, stack) {
      setLastStartError(_friendlyStartException(e));
      log('❌ 启动异常: $e');
      log('堆栈: $stack');
      await _stopInternal();
      return false;
    }
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
    final proxyCleared = await _stopInternal();
    if (!proxyCleared) {
      throw StateError(
        _proxyService.lastError ?? 'Windows 系统代理恢复失败，请再次尝试断开',
      );
    }
  }

  Future<bool> _stopInternal() async {
    final exitCleanup = _exitCleanupOperation;
    if (exitCleanup != null) await exitCleanup;
    stopStatusMonitor();
    resetHealthCheckFailures();

    // Restore Windows networking while the local proxy is still alive. If
    // registry recovery fails, keep the core running and let the caller keep
    // the app open for a retry; killing it first would strand all HTTP apps on
    // an unreachable localhost proxy.
    final proxyCleared = await _proxyService.clearSystemProxy();
    if (!proxyCleared) {
      if (_proxyService.lastError != null) {
        log('⚠️ ${_proxyService.lastError}');
      }
      if (isRunning) startStatusMonitor();
      notifyStatusChanged();
      return false;
    }

    if (_coreProcess != null) {
      _stoppingCore = true;
      try {
        _coreProcess!.kill(ProcessSignal.sigterm);
        await _coreProcess!.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            _coreProcess!.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      } catch (e) {
        log('停止异常: $e');
      } finally {
        _stoppingCore = false;
      }
      _coreProcess = null;
    }
    await _deleteCorePid();

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

  void _scheduleUnexpectedExitRecovery(int? generation, int exitCode) {
    final cleanup = _clearProxyAfterUnexpectedExit();
    final operation = cleanup.then<void>((_) {});
    _exitCleanupOperation = operation;
    cleanup.then((proxyCleared) {
      if (identical(_exitCleanupOperation, operation)) {
        _exitCleanupOperation = null;
      }
      unawaited(
        _recoverFromUnexpectedExit(generation, exitCode, proxyCleared),
      );
    });
  }

  Future<bool> _clearProxyAfterUnexpectedExit() async {
    try {
      final cleared = await _proxyService.clearSystemProxy();
      if (!cleared && _proxyService.lastError != null) {
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
  ) async {
    if (generation == null ||
        !isConnectionIntentCurrent(generation, connected: true)) {
      return;
    }
    if (!proxyCleared) {
      markConnectionLost();
      notifyRuntimeNotice(
        '连接已断开：核心异常退出，且系统代理恢复失败，请使用“诊断”重试恢复',
      );
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
      notifyRuntimeNotice('核心已自动恢复');
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
