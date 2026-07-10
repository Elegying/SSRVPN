part of 'clash_service.dart';

mixin _WindowsCoreLifecycle on ClashServiceBase {
  // ── Process management ──
  Process? _coreProcess;
  Future<bool>? _startOperation;
  Future<void>? _stopOperation;
  Future<void>? _exitCleanupOperation;
  bool _stoppingCore = false;

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
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
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
    final encodedPath = base64Encode(utf8.encode(_corePath));
    final script = '''
\$target = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$encodedPath'))
Get-CimInstance Win32_Process -Filter "Name='mihomo.exe'" |
  Where-Object { \$_.ExecutablePath -eq \$target } |
  ForEach-Object {
    Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue
    \$_.ProcessId
  }
''';
    try {
      final result = await _runPowerShell(
        script,
        timeout: const Duration(seconds: 8),
      );
      if (result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty) {
        log('已清理遗留的 Mihomo 进程');
      }
    } catch (e) {
      log('清理遗留核心失败: $e');
    }
  }

  Future<ProcessResult> _runPowerShell(
    String script, {
    Duration timeout = const Duration(seconds: 10),
  }) =>
      TimedProcessRunner.run(
        _powerShellExecutable(),
        [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          script,
        ],
        timeout: timeout,
        timeoutStderr: '电脑性能不足，请重新连接',
      );

  String _powerShellExecutable() {
    if (!Platform.isWindows) return 'powershell';
    final windowsDir =
        Platform.environment['SystemRoot'] ?? Platform.environment['WINDIR'];
    if (windowsDir != null && windowsDir.trim().isNotEmpty) {
      final executable = File(
        '$windowsDir${Platform.pathSeparator}System32'
        '${Platform.pathSeparator}WindowsPowerShell'
        '${Platform.pathSeparator}v1.0'
        '${Platform.pathSeparator}powershell.exe',
      );
      if (executable.existsSync()) return executable.path;
    }
    return 'powershell';
  }

  // ── clang-format off: Start / Stop ──

  /// 启动核心
  Future<bool> start() {
    final current = _startOperation;
    if (current != null) return current;

    final operation = _startInternal();
    _startOperation = operation;
    operation.then<void>(
      (_) => _clearStartOperation(operation),
      onError: (_, __) => _clearStartOperation(operation),
    );
    return operation;
  }

  Future<bool> _startInternal() async {
    final exitCleanup = _exitCleanupOperation;
    if (exitCleanup != null) await exitCleanup;
    final stopping = _stopOperation;
    if (stopping != null) await stopping;
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
      final environment = {'TMPDIR': tmpDir, 'TMP': tmpDir, 'TEMP': tmpDir};

      if (!await _validateConfig(environment)) {
        setLastStartError(
          lastStartError ?? 'Mihomo 配置校验失败，请打开运行日志查看具体配置错误',
        );
        return false;
      }

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
      int? startupExitCode;
      final startupOutput = <String>[];

      // 监听子进程输出
      startedProcess.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
        final message = line.trim();
        if (message.isEmpty) return;
        startupOutput.add(message);
        if (startupOutput.length > 30) startupOutput.removeAt(0);
        log('[mihomo] $message');
      });
      startedProcess.stderr
          .transform(utf8.decoder)
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
        if (isRunning) {
          setRunning(false);
          stopStatusMonitor();
          _coreProcess = null;
          notifyStatusChanged();
          _scheduleUnexpectedExitCleanup();
        }
      });

      // 慢速磁盘或首次启动可能超过 2 秒，轮询等待 API 就绪。
      var healthy = false;
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline) && startupExitCode == null) {
        healthy = await healthCheck();
        if (healthy) break;
        await Future.delayed(const Duration(milliseconds: 250));
      }

      if (healthy) {
        // 设置系统代理（非 TUN 模式时）
        if (!settings.enableTun) {
          final proxyWatch = Stopwatch()..start();
          final proxySet = await _proxyService.setSystemProxy(
            '127.0.0.1',
            settings.proxyPort,
          );
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
    await _stopInternal();
  }

  Future<void> _stopInternal() async {
    final exitCleanup = _exitCleanupOperation;
    if (exitCleanup != null) await exitCleanup;
    stopStatusMonitor();
    resetHealthCheckFailures();

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

    // 清除系统代理（在进程停止后执行）
    final proxyCleared = await _proxyService.clearSystemProxy();
    if (!proxyCleared && _proxyService.lastError != null) {
      log('⚠️ ${_proxyService.lastError}');
    }

    setRunning(false);
    notifyStatusChanged();
    log('核心已停止');
  }

  void _scheduleUnexpectedExitCleanup() {
    final operation = _clearProxyAfterUnexpectedExit();
    _exitCleanupOperation = operation;
    operation.whenComplete(() {
      if (identical(_exitCleanupOperation, operation)) {
        _exitCleanupOperation = null;
      }
    });
  }

  Future<void> _clearProxyAfterUnexpectedExit() async {
    try {
      final cleared = await _proxyService.clearSystemProxy();
      if (!cleared && _proxyService.lastError != null) {
        log('⚠️ ${_proxyService.lastError}');
      }
    } catch (error) {
      log('⚠️ 核心异常退出后清理系统代理失败: $error');
    }
  }

  void _clearStartOperation(Future<bool> operation) {
    if (identical(_startOperation, operation)) {
      _startOperation = null;
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
    Process? process;
    try {
      process = await Process.start(
        _corePath,
        ['-t', '-d', configDir, '-f', configPath],
        includeParentEnvironment: true,
        environment: environment,
      );
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode.timeout(
        const Duration(seconds: 40),
        onTimeout: () {
          process?.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      final stdout = (await stdoutFuture).trim();
      final stderr = (await stderrFuture).trim();
      if (stdout.isNotEmpty) log('[配置校验] $stdout');
      if (stderr.isNotEmpty) log('[配置校验 stderr] $stderr');
      if (exitCode == 0) {
        log('✅ Mihomo 配置校验通过，耗时 ${watch.elapsedMilliseconds}ms');
        return true;
      }
      if (exitCode == -1) {
        setLastStartError('电脑性能不足，请重新连接');
        log('❌ $lastStartError');
        return false;
      }
      final reason = _describeWindowsExitCode(exitCode);
      final detail = stderr.isNotEmpty ? stderr : stdout;
      if (reason != null) {
        setLastStartError('Mihomo 无法在此电脑运行: $reason');
      } else if (detail.isNotEmpty) {
        setLastStartError('Mihomo 配置校验失败: $detail');
      }
      log(
        '❌ Mihomo 配置校验失败，退出码: $exitCode'
        '${reason == null ? "" : "（$reason）"}',
      );
      if (lastStartError == null) {
        setLastStartError('Mihomo 配置校验失败，请打开运行日志查看具体配置错误');
      }
      return false;
    } catch (e) {
      process?.kill(ProcessSignal.sigkill);
      log('❌ 无法执行 Mihomo 配置校验: $e');
      return false;
    }
  }

  // ── Core path management ──

  void setCorePath(String path) => _corePath = path;
}
