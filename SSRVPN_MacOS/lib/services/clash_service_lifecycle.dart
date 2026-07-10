part of 'clash_service.dart';

mixin _MacosCoreLifecycle on ClashServiceBase {
  static const _filePath = '/usr/bin/file';
  static const _pkillPath = '/usr/bin/pkill';
  static const _tunUnavailableMessage =
      'macOS TUN 模式已暂时停用：当前版本没有安全的 Network Extension '
      '或特权辅助程序，请切换到系统代理模式。';

  Process? _clashProcess;
  bool _stoppingCore = false;
  Future<bool>? _startOperation;
  Future<void>? _stopOperation;
  Future<void>? _exitCleanupOperation;
  String _corePath = '';
  String? _startupDisabledReason;
  final SystemProxyService _proxyService = SystemProxyService();

  bool get isStartupDisabled => _startupDisabledReason != null;
  String? get startupDisabledReason => _startupDisabledReason;
  String get corePath => _corePath;
  bool get coreExists => File(_corePath).existsSync();

  Future<void> _verifyCoreForExecution();

  @override
  Future<void> onStopRequired() => stop();

  void disableStartup(String reason) {
    _startupDisabledReason = reason;
    setLastStartError(reason);
    log(reason);
  }

  Future<void> _logCoreVersion() async {
    await _verifyCoreForExecution();
    try {
      final stat = await File(_corePath).stat();
      log(
        '核心文件大小: ${(stat.size / 1024 / 1024).toStringAsFixed(1)} MB',
      );
    } catch (_) {}

    try {
      final fileInfo = await _runProcess(
        _filePath,
        [_corePath],
        timeout: const Duration(seconds: 5),
      );
      if (fileInfo.exitCode == 0 &&
          fileInfo.stdout.toString().trim().isNotEmpty) {
        log('核心架构: ${fileInfo.stdout.toString().trim()}');
      }
    } catch (_) {}

    try {
      await _verifyCoreForExecution();
      final result = await _runProcess(
        _corePath,
        ['-v'],
        workingDirectory: configDir,
        timeout: const Duration(seconds: 5),
      );
      final output = '${result.stdout}\n${result.stderr}'.trim();
      if (result.exitCode == 0 && output.isNotEmpty) {
        log('核心版本: ${output.replaceAll(RegExp(r'\s+'), ' ')}');
      } else if (result.exitCode == 124) {
        log('核心版本检查超时');
      } else {
        log('核心版本检查失败，退出码: ${result.exitCode}');
      }
    } catch (e) {
      log('核心无法执行: $e');
    }
  }

  Future<void> _terminateOrphanedCores() async {
    if (_corePath.isEmpty || !Platform.isMacOS) return;
    try {
      final result = await _runProcess(
        _pkillPath,
        ['-f', _corePath],
        timeout: const Duration(seconds: 5),
      );
      if (result.exitCode == 0) {
        log('已清理遗留的 Mihomo 进程');
      }
    } catch (e) {
      log('清理遗留核心失败: $e');
    }
  }

  void setCorePath(String path) {
    _corePath = path;
  }

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
    if (settings.enableTun) {
      setLastStartError(_tunUnavailableMessage);
      log(lastStartError!);
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
      _clashProcess = null;
      stopStatusMonitor();
    }

    try {
      final startupWatch = Stopwatch()..start();
      log('启动 Mihomo 核心...');
      log('核心路径: $_corePath');
      log('配置目录: $configDir');

      if (!File(_corePath).existsSync()) {
        setLastStartError('找不到核心文件，应用资源可能未完整安装');
        log('错误: 找不到核心文件 $_corePath');
        return false;
      }
      if (!File(configPath).existsSync()) {
        setLastStartError('找不到生成的 Mihomo 配置文件');
        log('错误: 找不到配置文件 $configPath');
        return false;
      }

      final tmpDir = '$configDir${Platform.pathSeparator}tmp';
      await Directory(tmpDir).create(recursive: true);
      final environment = {
        'TMPDIR': tmpDir,
        'TMP': tmpDir,
        'TEMP': tmpDir,
      };

      if (!await _validateConfig(environment)) {
        setLastStartError(
          lastStartError ?? 'Mihomo 配置校验失败，请打开运行日志查看具体错误',
        );
        return false;
      }

      await _verifyCoreForExecution();

      final processStartWatch = Stopwatch()..start();
      final startedProcess = await Process.start(
        _corePath,
        ['-d', configDir, '-f', configPath],
        workingDirectory: configDir,
        mode: ProcessStartMode.normal,
        includeParentEnvironment: true,
        environment: environment,
      );
      log(
        'Mihomo 进程已创建，耗时 ${processStartWatch.elapsedMilliseconds}ms',
      );
      _clashProcess = startedProcess;
      int? startupExitCode;
      final startupOutput = <String>[];

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

      startedProcess.exitCode.then((code) {
        startupExitCode = code;
        if (!identical(_clashProcess, startedProcess) || _stoppingCore) {
          return;
        }

        log('Mihomo 进程已退出，退出码: $code');
        if (isRunning) {
          setRunning(false);
          stopStatusMonitor();
          _clashProcess = null;
          notifyStatusChanged();
          _scheduleUnexpectedExitCleanup();
        }
      });

      var healthy = false;
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline) && startupExitCode == null) {
        healthy = await healthCheck();
        if (healthy) break;
        await Future.delayed(const Duration(milliseconds: 250));
      }

      if (healthy) {
        final proxySet = await _proxyService.setSystemProxy(
          '127.0.0.1',
          settings.proxyPort,
        );
        if (!proxySet) {
          setLastStartError(
            _proxyService.lastError ?? 'macOS 系统代理设置失败',
          );
          log(lastStartError!);
          await _stopInternal();
          return false;
        }
        log('macOS 系统代理已设置');

        final processStillHealthy = await healthCheck();
        final canCommitRunning = identical(_clashProcess, startedProcess) &&
            startupExitCode == null &&
            processStillHealthy;
        if (!canCommitRunning) {
          setLastStartError(
            startupExitCode == null
                ? 'Mihomo 在系统代理设置期间失去响应'
                : 'Mihomo 在系统代理设置期间退出（退出码 $startupExitCode）',
          );
          log(lastStartError!);
          await _stopInternal();
          return false;
        }

        setRunning(true);
        resetHealthCheckFailures();
        log(
          'Mihomo API 就绪，耗时 ${startupWatch.elapsedMilliseconds}ms',
        );

        notifyStatusChanged();
        startStatusMonitor();
        return true;
      }

      if (startupExitCode != null) {
        final detail = startupOutput.isEmpty ? '' : ': ${startupOutput.last}';
        setLastStartError(
          'Mihomo 提前退出（退出码 $startupExitCode）$detail',
        );
      } else {
        setLastStartError('电脑性能不足或核心启动过慢，请重新连接');
      }
      log('核心启动失败: $lastStartError');
      await _stopInternal();
      return false;
    } catch (e, stack) {
      setLastStartError(_friendlyStartException(e));
      log('启动核心异常: $e');
      log('堆栈: $stack');
      await _stopInternal();
      return false;
    }
  }

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

    final process = _clashProcess;
    if (process != null) {
      _stoppingCore = true;
      try {
        process.kill(ProcessSignal.sigterm);
        await process.exitCode.timeout(
          const Duration(seconds: 3),
          onTimeout: () {
            process.kill(ProcessSignal.sigkill);
            return -1;
          },
        );
      } catch (e) {
        log('停止核心异常: $e');
      } finally {
        _stoppingCore = false;
      }
      _clashProcess = null;
    }

    final proxyCleared = await _proxyService.clearSystemProxy();
    if (!proxyCleared && _proxyService.lastError != null) {
      log(_proxyService.lastError!);
    }

    setRunning(false);
    notifyStatusChanged();
    log('Mihomo 核心已停止');
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
        log(_proxyService.lastError!);
      }
    } catch (error) {
      log('核心异常退出后清理系统代理失败: $error');
    } finally {
      try {
        onProcessExit?.call();
      } catch (error) {
        log('核心退出回调失败: $error');
      }
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

  Future<bool> _validateConfig(Map<String, String> environment) async {
    log('正在校验 Mihomo 配置...');
    final watch = Stopwatch()..start();
    try {
      await _verifyCoreForExecution();
      final result = await _runProcess(
        _corePath,
        ['-t', '-d', configDir, '-f', configPath],
        workingDirectory: configDir,
        includeParentEnvironment: true,
        environment: environment,
        timeout: const Duration(seconds: 40),
      );
      final stdout = result.stdout.toString().trim();
      final stderr = result.stderr.toString().trim();
      if (stdout.isNotEmpty) log('[配置校验] $stdout');
      if (stderr.isNotEmpty) log('[配置校验 stderr] $stderr');
      if (result.exitCode == 0) {
        log('Mihomo 配置校验通过，耗时 ${watch.elapsedMilliseconds}ms');
        return true;
      }
      if (result.exitCode == 124) {
        setLastStartError('电脑性能不足或配置校验超时，请重新连接');
      } else if (stderr.isNotEmpty || stdout.isNotEmpty) {
        setLastStartError(
          'Mihomo 配置校验失败: ${stderr.isNotEmpty ? stderr : stdout}',
        );
      }
      log('Mihomo 配置校验失败，退出码: ${result.exitCode}');
      return false;
    } catch (e) {
      setLastStartError(_friendlyStartException(e));
      log('无法执行 Mihomo 配置校验: $e');
      return false;
    }
  }

  String _friendlyStartException(Object error) {
    final message = error.toString();
    final lower = message.toLowerCase();
    if (lower.contains('permission denied') ||
        lower.contains('operation not permitted') ||
        lower.contains('权限') ||
        lower.contains('拒绝')) {
      return '无法执行 Mihomo，核心文件权限异常';
    }
    if (lower.contains('bad cpu type') ||
        lower.contains('exec format') ||
        lower.contains('unsupported architecture')) {
      return 'Mihomo 与当前 Mac 架构不兼容';
    }
    return '启动 Mihomo 时发生异常: $message';
  }

  Future<ProcessResult> _runProcess(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    bool includeParentEnvironment = true,
    Map<String, String>? environment,
    Duration timeout = const Duration(seconds: 10),
  }) =>
      TimedProcessRunner.run(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        includeParentEnvironment: includeParentEnvironment,
        environment: environment,
        timeout: timeout,
      );
}
