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

part 'clash_service_config.dart';

/// macOS Clash Meta 核心管理服务
///
/// 继承 [ClashServiceBase] 复用公共 API、延迟测试、健康检查等逻辑，
/// 仅保留 macOS 特有的进程管理、资源释放和系统代理集成。
class ClashService extends ClashServiceBase with _MacosClashConfig {
  // ── macOS 静态路径 ──
  static const _chmodPath = '/bin/chmod';
  static const _filePath = '/usr/bin/file';
  static const _pkillPath = '/usr/bin/pkill';
  static const _coreName = 'AtlasCore';
  static const _coreManifestAsset = 'assets/AtlasCore-source.txt';
  static const _privilegedModeBits = 0xc00;
  static const _tunUnavailableMessage =
      'macOS TUN 模式已暂时停用：当前版本没有安全的 Network Extension '
      '或特权辅助程序，请切换到系统代理模式。';

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

    await _ensureRealDirectory(configDir);
    await Directory(
      '$configDir${Platform.pathSeparator}providers',
    ).create(recursive: true);
    _logFile = File('$configDir${Platform.pathSeparator}ssrvpn.log');
    await _rotateLogFile();
    await _proxyService.initialize(configDir);

    _corePath = '$configDir${Platform.pathSeparator}$_coreName';

    // 初始化 HTTP 客户端
    initHttpClient();

    // 核心是可执行文件：先移除不可信的旧路径项，再安装普通用户文件。
    await _installCoreAsset(
      'assets/AtlasCore.gz',
      _corePath,
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

  Future<void> _ensureRealDirectory(String path) async {
    final initialType = await FileSystemEntity.type(path, followLinks: false);
    if (initialType == FileSystemEntityType.notFound) {
      await Directory(path).create(recursive: true);
    } else if (initialType != FileSystemEntityType.directory) {
      throw FileSystemException(
        'Refusing to use a linked or non-directory data path',
        path,
      );
    }
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException('Data directory changed during setup', path);
    }
  }

  /// 安装可执行核心。目标和 revision 标记都按不可信路径处理，绝不跟随链接。
  Future<void> _installCoreAsset(String assetKey, String destPath) async {
    final data = await rootBundle.load(assetKey);
    final compressedBytes = data.buffer.asUint8List();
    final revision = crypto.sha256.convert(compressedBytes).toString();
    final expectedExecutableDigest = await _loadExpectedCoreDigest();
    final markerPath = '$destPath.rev';

    if (await _canReuseInstalledCore(
      destPath,
      markerPath,
      revision,
      expectedExecutableDigest,
    )) {
      return;
    }

    // 先解除旧核心在固定路径上的可达性，之后才进行解压和写入。
    await _removeUntrustedPathEntry(destPath);
    await _removeUntrustedPathEntry(markerPath);

    final compressed = compressedBytes;
    final bytes = Uint8List.fromList(
      await Isolate.run(() => gzip.decode(compressed)),
    );
    if (crypto.sha256.convert(bytes).toString() != expectedExecutableDigest) {
      throw StateError('Bundled Mihomo core does not match its trusted digest');
    }
    await _replaceRegularFile(destPath, bytes, executable: true);
    await _replaceRegularFile(markerPath, utf8.encode(revision));
    log('已安全释放核心: $assetKey -> $destPath');
  }

  Future<bool> _canReuseInstalledCore(
    String corePath,
    String markerPath,
    String revision,
    String expectedExecutableDigest,
  ) async {
    if (!await _isRegularUnprivilegedFile(corePath)) return false;
    if (await FileSystemEntity.type(markerPath, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    try {
      final marker = File(markerPath);
      if (await marker.length() != revision.length ||
          await marker.readAsString() != revision) {
        return false;
      }
      if (await _fileSha256(corePath) != expectedExecutableDigest ||
          await FileSystemEntity.type(corePath, followLinks: false) !=
              FileSystemEntityType.file) {
        return false;
      }
      await _setExecutableMode(corePath);
      return _isRegularUnprivilegedFile(corePath);
    } catch (_) {
      return false;
    }
  }

  Future<String> _loadExpectedCoreDigest() async {
    final manifest = await rootBundle.loadString(_coreManifestAsset);
    final match = RegExp(
      r'^Executable SHA256: ([0-9a-f]{64})$',
      multiLine: true,
    ).firstMatch(manifest);
    if (match == null) {
      throw const FormatException(
        'AtlasCore source manifest is missing Executable SHA256',
      );
    }
    return match[1]!;
  }

  Future<String> _fileSha256(String path) async {
    final digest = await crypto.sha256.bind(File(path).openRead()).first;
    return digest.toString();
  }

  Future<void> _replaceRegularFile(
    String path,
    List<int> bytes, {
    bool executable = false,
  }) async {
    final temp = File(
      '$path.tmp.$pid.${DateTime.now().microsecondsSinceEpoch}',
    );
    await temp.create(exclusive: true);
    try {
      final handle = await temp.open(mode: FileMode.writeOnly);
      try {
        await handle.writeFrom(bytes);
        await handle.flush();
      } finally {
        await handle.close();
      }
      if (executable) {
        await _setExecutableMode(temp.path);
        if (!await _isRegularUnprivilegedFile(temp.path)) {
          throw FileSystemException('Unsafe temporary core file', temp.path);
        }
      }

      // Re-check immediately before rename in case the user-writable directory
      // changed while bytes were being written.
      await _removeUntrustedPathEntry(path);
      await temp.rename(path);

      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw FileSystemException('Installed path is not a regular file', path);
      }
      if (executable && !await _isRegularUnprivilegedFile(path)) {
        throw FileSystemException('Installed core has unsafe mode bits', path);
      }
    } finally {
      final type = await FileSystemEntity.type(temp.path, followLinks: false);
      if (type == FileSystemEntityType.file ||
          type == FileSystemEntityType.link) {
        await temp.delete();
      }
    }
  }

  Future<void> _removeUntrustedPathEntry(String path) async {
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.file ||
        type == FileSystemEntityType.link) {
      await File(path).delete();
      return;
    }
    throw FileSystemException(
      'Refusing to replace a non-file core path entry',
      path,
    );
  }

  Future<bool> _isRegularUnprivilegedFile(String path) async {
    if (await FileSystemEntity.type(path, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    final stat = await File(path).stat();
    if (stat.type != FileSystemEntityType.file ||
        (stat.mode & _privilegedModeBits) != 0) {
      return false;
    }
    return await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.file;
  }

  Future<void> _setExecutableMode(String path) async {
    final result = await _runProcess(
      _chmodPath,
      ['755', path],
      timeout: const Duration(seconds: 5),
    );
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Unable to set safe executable mode: ${result.stderr}'.trim(),
        path,
      );
    }
  }

  Future<void> _verifyCoreForExecution() async {
    if (!await _isRegularUnprivilegedFile(_corePath)) {
      throw FileSystemException(
        'Mihomo core is not a regular unprivileged file',
        _corePath,
      );
    }
  }

  /// 从应用包内释放非可执行资源文件到目标路径。
  Future<void> _installAsset(
    String assetKey,
    String destPath,
  ) async {
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
      if (!existingMatches) {
        await writeBytesAtomically(dest, bytes);
        log('已释放资源: $assetKey -> $destPath');
      }
      await writeStringAtomically(marker, assetRevision);
    } catch (e) {
      log('释放资源失败 $assetKey: $e');
    }
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
  // 配置校验
  // ═══════════════════════════════════════════════════════════

  Future<bool> _validateConfig(
    Map<String, String> environment,
  ) async {
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
