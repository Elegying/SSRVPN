import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'package:ssrvpn_shared/ssrvpn_shared.dart';

import 'system_proxy_service.dart';

/// macOS Clash Meta 核心管理服务
///
/// 继承 [ClashServiceBase] 复用公共 API、延迟测试、健康检查等逻辑，
/// 仅保留 macOS 特有的进程管理、资源释放和系统代理集成。
class ClashService extends ClashServiceBase {
  // ── macOS 静态路径 ──
  static const _chmodPath = '/bin/chmod';
  static const _chownPath = '/usr/sbin/chown';
  static const _filePath = '/usr/bin/file';
  static const _osascriptPath = '/usr/bin/osascript';
  static const _pkillPath = '/usr/bin/pkill';
  static const _statPath = '/usr/bin/stat';
  static const _coreName = 'AtlasCore';

  // ── macOS 进程管理 ──
  Process? _clashProcess;
  bool _stoppingCore = false;
  Future<bool>? _startOperation;
  Future<void>? _stopOperation;
  Future<void>? _exitCleanupOperation;

  // ── macOS 文件与日志 ──
  String _corePath = '';
  File? _logFile;
  Future<void> _pendingLogWrite = Future<void>.value();

  // ── macOS 启动控制 ──
  String? _startupDisabledReason;

  // ── macOS 系统代理 ──
  final SystemProxyService _proxyService = SystemProxyService();

  // ── Getters ──
  bool get isStartupDisabled => _startupDisabledReason != null;
  String? get startupDisabledReason => _startupDisabledReason;
  String get logPath => _logFile?.path ?? '';
  String get corePath => _corePath;
  bool get coreExists => File(_corePath).existsSync();

  // ═══════════════════════════════════════════════════════════
  // 覆写：Base 方法
  // ═══════════════════════════════════════════════════════════

  @override
  Future<void> onStopRequired() async {
    await stop();
  }

  @override
  void log(String message) {
    super.log(message);
    // macOS: 写入文件日志
    final logFile = _logFile;
    if (logFile != null) {
      final sanitized = LogRedactor.sanitize(message);
      final line = '[${DateTime.now().toIso8601String()}] $sanitized\n';
      _pendingLogWrite = _pendingLogWrite
          .then(
            (_) => logFile.writeAsString(
              line,
              mode: FileMode.append,
              flush: true,
            ),
          )
          .then<void>((_) {})
          .catchError((Object _, StackTrace __) {});
    }
  }

  @override
  @protected
  void debugLog(String message) {
    AppLogger.info('Clash', message);
  }

  // ═══════════════════════════════════════════════════════════
  // 初始化
  // ═══════════════════════════════════════════════════════════

  void disableStartup(String reason) {
    _startupDisabledReason = reason;
    setLastStartError(reason);
    log(reason);
  }

  /// 初始化服务，设置路径
  ///
  /// macOS：数据保存在 ~/Library/Application Support/SSRVPN，
  /// 核心与 geoip 数据库随应用打包，首次运行时释放到该目录。
  Future<void> init(
    AppSettings settings, {
    String? dataDir,
    String? storageNotice,
    bool skipCoreProbes = false,
  }) async {
    updateSettings(settings);
    _startupDisabledReason = null;

    String configDir;
    if (dataDir != null && dataDir.isNotEmpty) {
      configDir = dataDir;
    } else {
      final supportDir = await getApplicationSupportDirectory();
      configDir = '${supportDir.path}${Platform.pathSeparator}SSRVPN';
    }
    final configPath = '$configDir${Platform.pathSeparator}config.yaml';
    setPaths(configDir: configDir, configPath: configPath);

    await Directory(configDir).create(recursive: true);
    await Directory(
      '$configDir${Platform.pathSeparator}providers',
    ).create(recursive: true);
    _logFile = File('$configDir${Platform.pathSeparator}ssrvpn.log');
    await _rotateLogFile();
    await _proxyService.initialize(configDir);

    _corePath = '$configDir${Platform.pathSeparator}$_coreName';

    // 初始化 HTTP 客户端
    initHttpClient();

    // 资源以 gzip 压缩形式打包以减小安装体积，首次运行时解压释放
    await _installAsset(
      'assets/AtlasCore.gz',
      _corePath,
      executable: true,
    );
    await _installAsset(
      'assets/geoip.metadb.gz',
      '$configDir${Platform.pathSeparator}geoip.metadb',
    );
    if (!skipCoreProbes) {
      await _terminateOrphanedCores();
    }

    log('系统: ${Platform.operatingSystemVersion}');
    log('程序路径: ${Platform.resolvedExecutable}');
    log('配置目录: $configDir');
    log('核心路径: $_corePath');
    log('诊断日志: ${_logFile!.path}');
    if (storageNotice != null && storageNotice.isNotEmpty) {
      log(storageNotice);
    }
    if (_proxyService.lastError != null) {
      log(_proxyService.lastError!);
    }
    if (!skipCoreProbes) {
      await _logCoreVersion();
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 资源配置
  // ═══════════════════════════════════════════════════════════

  Future<void> _rotateLogFile() async {
    final logFile = _logFile;
    if (logFile == null || !await logFile.exists()) return;
    if (await logFile.length() < 2 * 1024 * 1024) return;

    final oldFile = File('${logFile.path}.old');
    if (await oldFile.exists()) await oldFile.delete();
    await logFile.rename(oldFile.path);
  }

  /// 从应用包内释放资源文件到目标路径（仅在不存在或资源更新时写入）
  /// .gz 资源自动解压
  Future<void> _installAsset(
    String assetKey,
    String destPath, {
    bool executable = false,
  }) async {
    try {
      final dest = File(destPath);
      final marker = File('$destPath.rev');
      final data = await rootBundle.load(assetKey);
      final compressedBytes = data.buffer.asUint8List();
      final assetRevision = crypto.sha256.convert(compressedBytes).toString();

      // marker 记录源资源 SHA256；一致则跳过昂贵的 gzip 解压
      if (await dest.exists() &&
          await marker.exists() &&
          (await marker.readAsString()) == assetRevision) {
        if (executable) {
          await _chmodExec(destPath);
        }
        return;
      }

      var bytes = compressedBytes;
      if (assetKey.endsWith('.gz')) {
        final compressed = bytes;
        // 核心二进制解压有几十 MB，放后台 isolate 避免卡 UI
        bytes = Uint8List.fromList(
          await Isolate.run(() => gzip.decode(compressed)),
        );
      }
      final existingMatches = await _fileContentMatches(dest, bytes);
      // 核心被授予 setuid root 后可能无法覆盖写；内容未变时跳过即可。
      if (!existingMatches) {
        await writeBytesAtomically(dest, bytes);
        log('已释放资源: $assetKey -> $destPath');
      }
      await writeStringAtomically(marker, assetRevision);
      if (executable) await _chmodExec(destPath);
    } catch (e) {
      log('释放资源失败 $assetKey: $e');
    }
  }

  Future<void> _chmodExec(String path) async {
    try {
      // 注意：核心被授予 setuid root 后此处会因权限失败，静默忽略即可
      await _runProcess(_chmodPath, ['755', path],
          timeout: const Duration(seconds: 5));
    } catch (_) {}
  }

  Future<bool> _fileContentMatches(File file, List<int> bytes) async {
    if (!await file.exists()) return false;
    if (await file.length() != bytes.length) return false;
    final digest = crypto.sha256.convert(await file.readAsBytes()).toString();
    final expected = crypto.sha256.convert(bytes).toString();
    return digest == expected;
  }

  // ═══════════════════════════════════════════════════════════
  // 核心探测
  // ═══════════════════════════════════════════════════════════

  Future<void> _logCoreVersion() async {
    if (!await File(_corePath).exists()) {
      log('核心文件不存在: $_corePath');
      return;
    }
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

  // ═══════════════════════════════════════════════════════════
  // 配置生成（macOS 专用）
  // ═══════════════════════════════════════════════════════════

  String _macosTunConfig(AppSettings settings) {
    final buffer = StringBuffer()
      ..writeln('tun:')
      ..writeln('  enable: true')
      ..writeln('  stack: ${settings.tunStack}')
      ..writeln('  auto-route: true')
      ..writeln('  auto-detect-interface: true')
      ..writeln('  route-exclude-address:');
    for (final address in AppConstants.routeExcludeAddresses) {
      buffer.writeln('    - $address');
    }
    buffer
      ..writeln('  dns-hijack:')
      ..writeln('    - any:53')
      ..writeln('  route-address-set:')
      ..writeln('    - geoip-cn')
      ..writeln('    - geosite-cn');
    return buffer.toString().trimRight();
  }

  /// 生成 Clash 配置（订阅只取节点，规则和分流完全内置）
  String generateClashConfig(
    String rawYaml,
    AppSettings settings, {
    String? preferredNodeName,
  }) {
    return buildClashConfig(
      rawYaml,
      settings,
      preferredNodeName: preferredNodeName,
      platformHeader: '# ===== SSRVPN 配置（规则内置，订阅仅加载节点） =====',
      tunConfig: settings.enableTun ? _macosTunConfig(settings) : null,
      latencyTestUrl: settings.latencyTestUrl,
      includeFallbackGroup: true,
      includeGeoIpRules: true,
    );
  }

  /// 将配置写入文件
  Future<void> writeConfig(String configContent) async {
    final file = File(configPath);
    await writeStringAtomically(file, configContent);
  }

  // ═══════════════════════════════════════════════════════════
  // 进程管理
  // ═══════════════════════════════════════════════════════════

  /// 设置核心路径（用于用户自定义路径）
  void setCorePath(String path) {
    _corePath = path;
  }

  /// 启动 Clash 核心
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

      if (settings.enableTun && !await _coreHasRootPrivilege()) {
        final granted = await _grantRootPrivilege();
        if (!granted) {
          setLastStartError(
            lastStartError ?? 'TUN 模式需要管理员授权，已取消',
          );
          log(lastStartError!);
          return false;
        }
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
        if (!settings.enableTun) {
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
        }

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
        setLastStartError(
          '电脑性能不足或核心启动过慢，请重新连接',
        );
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

  /// 停止 Clash 核心
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

  // ═══════════════════════════════════════════════════════════
  // core 权限管理（macOS TUN 模式专用）
  // ═══════════════════════════════════════════════════════════

  /// 核心是否已具备 root 权限（owner=root 且 setuid 位）
  Future<bool> _coreHasRootPrivilege() async {
    try {
      final result = await _runProcess(
        _statPath,
        ['-f', '%Su %Mp%Lp', _corePath],
        timeout: const Duration(seconds: 5),
      );
      if (result.exitCode != 0) return false;
      final parts = (result.stdout as String).trim().split(' ');
      if (parts.length != 2) return false;
      final isRoot = parts[0] == 'root';
      final hasSetuid = parts[1].length >= 4 && parts[1][0] == '4';
      return isRoot && hasSetuid;
    } catch (_) {
      return false;
    }
  }

  /// 弹出系统授权窗口，为核心设置 setuid root（仅首次开启 TUN 时需要）
  Future<bool> _grantRootPrivilege() async {
    try {
      final escaped = _corePath.replaceAll('"', '\\"');
      final script = 'do shell script '
          '"$_chownPath root:wheel \\"$escaped\\"'
          ' && $_chmodPath u+s \\"$escaped\\"" '
          'with administrator privileges'
          ' with prompt "SSRVPN 需要管理员权限以启用 TUN 模式"';
      final result = await _runProcess(
        _osascriptPath,
        ['-e', script],
        timeout: const Duration(minutes: 2),
      );
      if (result.exitCode == 124) {
        setLastStartError(
          'TUN 授权超时，请重新连接并在系统弹窗中完成管理员授权',
        );
        return false;
      }
      if (result.exitCode != 0) {
        final stderr = result.stderr.toString().trim();
        setLastStartError(
          stderr.isEmpty ? 'TUN 模式需要管理员授权，已取消' : 'TUN 授权失败: $stderr',
        );
      }
      return result.exitCode == 0;
    } catch (_) {
      setLastStartError('无法弹出 TUN 管理员授权窗口');
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 配置校验
  // ═══════════════════════════════════════════════════════════

  Future<bool> _validateConfig(
    Map<String, String> environment,
  ) async {
    log('正在校验 Mihomo 配置...');
    final watch = Stopwatch()..start();
    try {
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
        log(
          'Mihomo 配置校验通过，耗时 ${watch.elapsedMilliseconds}ms',
        );
        return true;
      }
      if (result.exitCode == 124) {
        setLastStartError(
          '电脑性能不足或配置校验超时，请重新连接',
        );
      } else if (stderr.isNotEmpty || stdout.isNotEmpty) {
        setLastStartError(
          'Mihomo 配置校验失败: '
          '${stderr.isNotEmpty ? stderr : stdout}',
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

  // ═══════════════════════════════════════════════════════════
  // 工具方法
  // ═══════════════════════════════════════════════════════════

  String _friendlyStartException(Object error) {
    final message = error.toString();
    final lower = message.toLowerCase();
    if (lower.contains('permission denied') ||
        lower.contains('operation not permitted') ||
        lower.contains('权限') ||
        lower.contains('拒绝')) {
      return '无法执行 Mihomo，可能缺少权限或 TUN 授权未完成';
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
