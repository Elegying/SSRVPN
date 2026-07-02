import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:ssrvpn_shared/services/clash_config_generator.dart';
import 'package:ssrvpn_shared/services/clash_service_base.dart';
import 'package:ssrvpn_shared/utils/log_redactor.dart';

import '../models/app_settings.dart';
import '../services/system_proxy_service.dart';

/// Clash Meta 核心管理服务 (Windows 版)
///
/// 通过 spawn mihomo.exe 子进程启动核心，使用 REST API 控制。
/// 支持 TUN 模式（需管理员权限）和系统代理模式。
class ClashService extends ClashServiceBase {
  // ── Windows-specific constants ──
  static const String _geoProxyGroupName = 'SSRVPN-GEO';
  static const List<String> _geoLookupHosts = [
    'api.country.is',
    'ipinfo.io',
    'ifconfig.co',
  ];

  // ── Process management ──
  Process? _coreProcess;
  Future<bool>? _startOperation;
  Future<void>? _stopOperation;
  bool _stoppingCore = false;

  // ── Startup disabled ──
  String? _startupDisabledReason;

  // ── File logging ──
  File? _logFile;
  Future<void> _pendingLogWrite = Future<void>.value();

  // ── System proxy ──
  final SystemProxyService _proxyService = SystemProxyService();

  // ── Core path ──
  String _corePath = '';

  // ── Getters ──
  bool get isStartupDisabled => _startupDisabledReason != null;
  String? get startupDisabledReason => _startupDisabledReason;
  String get logPath => _logFile?.path ?? '';
  bool get coreExists => File(_corePath).existsSync();
  String get corePath => _corePath;

  // ── Lifecycle overrides ──

  @override
  Future<void> onStopRequired() async {
    await stop();
  }

  @override
  void debugLog(String message) {
    debugPrint('[Clash] $message');
  }

  // Windows prefers a shorter connection timeout for the Clash API client.
  // Because the base class manages the HttpClient internally, the subclass
  // can't replace it; the 1 s difference is negligible in practice.
  // Keeping _createDirectHttpClient as a reference if base API changes.
  // ignore: unused_element
  static HttpClient _createDirectHttpClient() {
    final client = HttpClient();
    client.findProxy = (_) => 'DIRECT';
    client.connectionTimeout = const Duration(seconds: 2);
    return client;
  }

  @override
  void updateSettings(AppSettings settings) {
    if (apiClient == null) {
      initHttpClient();
    }
    super.updateSettings(settings);
  }

  @override
  void log(String message) {
    super.log(message);
    if (!kReleaseMode) {
      final logFile = _logFile;
      if (logFile != null) {
        final sanitized = LogRedactor.sanitize(message);
        final line = '[${DateTime.now().toIso8601String()}] $sanitized\r\n';
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
  }

  // ── Windows process management ──

  void disableStartup(String reason) {
    _startupDisabledReason = reason;
    setLastStartError(reason);
    log(reason);
  }

  /// 初始化服务
  Future<void> init(
    AppSettings settings, {
    String? dataDir,
    String? storageNotice,
    bool skipCoreProbes = false,
  }) async {
    super.updateSettings(settings);
    initHttpClient();
    _startupDisabledReason = null;

    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final dir = dataDir ?? '$exeDir${Platform.pathSeparator}ssrvpn';
    setPaths(
      configDir: dir,
      configPath: '$dir${Platform.pathSeparator}config.yaml',
    );
    _corePath = '$exeDir${Platform.pathSeparator}mihomo.exe';
    await Directory(configDir).create(recursive: true);
    _logFile = File('$configDir${Platform.pathSeparator}ssrvpn.log');
    await _rotateLogFile();
    await _proxyService.initialize(configDir);
    if (!skipCoreProbes) {
      await _terminateOrphanedCores();
    }

    log('系统: ${Platform.operatingSystemVersion}');
    log('程序路径: ${Platform.resolvedExecutable}');
    log('配置目录: $configDir');
    log('核心路径: $_corePath');
    log('诊断日志: ${_logFile!.path}');
    if (storageNotice != null && storageNotice.isNotEmpty) {
      log('⚠️ $storageNotice');
    }
    if (_proxyService.lastError != null) {
      log('⚠️ ${_proxyService.lastError}');
    }

    // 验证核心文件
    final coreFile = File(_corePath);
    if (await coreFile.exists()) {
      final size = await coreFile.length();
      log('✅ 核心文件存在: ${(size / 1024 / 1024).toStringAsFixed(1)} MB');
      if (!skipCoreProbes) {
        await _logCoreVersion();
      }
    } else {
      log('❌ 核心文件不存在: $_corePath');
      log('请将 mihomo.exe 放到应用目录下');
    }

    // 预下载 MMDB 文件
    if (!skipCoreProbes) {
      await _ensureMMDB();
    }
  }

  Future<void> _rotateLogFile() async {
    final logFile = _logFile;
    if (logFile == null || !await logFile.exists()) return;
    if (await logFile.length() < 2 * 1024 * 1024) return;

    final oldFile = File('${logFile.path}.old');
    if (await oldFile.exists()) await oldFile.delete();
    await logFile.rename(oldFile.path);
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
  }) async {
    Process? process;
    try {
      process = await Process.start(_powerShellExecutable(), [
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ]);
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.transform(utf8.decoder).join();
      final exitCode = await process.exitCode.timeout(
        timeout,
        onTimeout: () {
          process?.kill(ProcessSignal.sigkill);
          return 124;
        },
      );

      final stdout = await stdoutFuture;
      final stderr = exitCode == 124 ? '电脑性能不足，请重新连接' : await stderrFuture;
      return ProcessResult(process.pid, exitCode, stdout, stderr);
    } catch (_) {
      process?.kill(ProcessSignal.sigkill);
      rethrow;
    }
  }

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

  /// 预下载 MMDB 文件
  Future<void> _ensureMMDB() async {
    final metadbPath = '$configDir${Platform.pathSeparator}geoip.metadb';
    final mmdbPath = '$configDir${Platform.pathSeparator}country.mmdb';

    try {
      final m = File(metadbPath);
      if (await m.exists() && await m.length() > 1024 * 1024) {
        log('✅ MMDB 已存在');
        return;
      }
      final g = File(mmdbPath);
      if (await g.exists() && await g.length() > 1024 * 1024) {
        log('✅ MMDB 已存在');
        return;
      }
    } catch (_) {}

    // 从内置资源复制（gzip 压缩）
    try {
      await Directory(configDir).create(recursive: true);
      final assetPath =
          '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets${Platform.pathSeparator}assets${Platform.pathSeparator}geoip.metadb.gz';
      final compressed = await File(assetPath).readAsBytes();
      final bytes = gzip.decode(compressed);
      final file = File(metadbPath);
      final temp = File('$metadbPath.tmp');
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(file.path);
      log(
        '✅ MMDB 已从内置资源解压 (${(bytes.length / 1024 / 1024).toStringAsFixed(1)} MB)',
      );
    } catch (e) {
      log('⚠️ MMDB 资源复制失败: $e');
      log('❌ MMDB 不可用，GEOIP 规则将跳过');
    }
  }

  // ── Config generation ──

  /// 生成 Clash 配置（Windows 专用：含 SSRVPN-GEO 组和 Windows 专用规则）
  String generateClashConfig(
    String rawYaml,
    AppSettings appSettings, {
    String? preferredNodeName,
  }) {
    final proxyNames = extractProxyNames(rawYaml);
    final proxiesText = extractSection(rawYaml, 'proxies');
    if (proxyNames.isEmpty || proxiesText.isEmpty) {
      throw Exception('订阅中没有可用节点，请先刷新订阅');
    }

    final selectedProxyNames = List<String>.from(proxyNames);
    if (preferredNodeName != null &&
        selectedProxyNames.remove(preferredNodeName)) {
      selectedProxyNames.insert(0, preferredNodeName);
    }

    final mmdbExists = (() {
      try {
        final m = File('$configDir${Platform.pathSeparator}country.mmdb');
        if (m.existsSync() && m.lengthSync() > 1024 * 1024) return true;
        final g = File('$configDir${Platform.pathSeparator}geoip.metadb');
        if (g.existsSync() && g.lengthSync() > 1024 * 1024) return true;
      } catch (_) {}
      return false;
    })();

    final result = StringBuffer();
    result.writeln('# ===== SSRVPN Windows =====');
    result.writeln('mixed-port: ${appSettings.proxyPort}');
    result.writeln('socks-port: ${appSettings.socksPort}');
    result.writeln('allow-lan: false');
    result.writeln('mode: ${appSettings.proxyMode.name}');
    result.writeln('log-level: info');
    result.writeln(
      "external-controller: '127.0.0.1:${appSettings.apiPort}'",
    );
    result.writeln('# SSRVPN 当前明确只支持 IPv4 节点与 IPv4 流量');
    result.writeln('ipv6: false');
    if (appSettings.apiSecret.isNotEmpty) {
      result.writeln('secret: ${yamlQuote(appSettings.apiSecret)}');
    }

    // TUN 模式配置
    result.writeln();
    result.writeln('tun:');
    result.writeln('  enable: ${appSettings.enableTun}');
    result.writeln('  stack: ${appSettings.tunStack}');
    result.writeln('  dns-hijack:');
    result.writeln('    - any:53');
    result.writeln('  auto-route: true');
    result.writeln('  auto-detect-interface: true');
    result.writeln('  route-exclude-address:');
    result.writeln('    - 192.168.0.0/16');
    result.writeln('    - 10.0.0.0/8');
    result.writeln('    - 172.16.0.0/12');
    result.writeln('    - 100.64.0.0/10');

    // DNS
    result.writeln();
    result.writeln('dns:');
    result.writeln('  enable: true');
    result.writeln('  ipv6: false');
    result.writeln('  enhanced-mode: fake-ip');
    result.writeln('  fake-ip-range: 198.18.0.1/16');
    result.writeln('  default-nameserver:');
    result.writeln('    - 223.5.5.5');
    result.writeln('    - 119.29.29.29');
    result.writeln('  nameserver:');
    result.writeln('    - https://dns.alidns.com/dns-query');
    result.writeln('    - https://doh.pub/dns-query');
    result.writeln('    - 223.5.5.5');
    result.writeln('    - 119.29.29.29');
    result.writeln('  fallback:');
    result.writeln('    - https://dns.google/dns-query');
    result.writeln('    - https://cloudflare-dns.com/dns-query');
    result.writeln('    - 8.8.8.8');
    result.writeln('    - 1.1.1.1');
    result.writeln('  fallback-filter:');
    result.writeln('    geoip: true');
    result.writeln('    geoip-code: CN');
    result.writeln('    ipcidr:');
    result.writeln('      - 240.0.0.0/4');
    result.writeln('    domain:');
    result.writeln("      - '*.google.com'");
    result.writeln("      - '*.googlevideo.com'");
    result.writeln("      - '*.youtube.com'");
    result.writeln("      - '*.ytimg.com'");
    result.writeln("      - '*.ggpht.com'");
    result.writeln('  fake-ip-filter:');
    result.writeln("    - '*.lan'");
    result.writeln("    - '*.local'");
    result.writeln("    - '*.localhost'");
    result.writeln("    - '*.googlevideo.com'");
    result.writeln("    - '*.youtube.com'");
    result.writeln("    - '*.ytimg.com'");
    result.writeln("    - '*.ggpht.com'");
    result.writeln("    - '*.googleapis.com'");
    result.writeln("    - 'dns.google'");
    result.writeln("    - 'www.google.com'");

    // Proxies
    result.writeln();
    result.writeln('proxies:');
    result.writeln(proxiesText);

    // Proxy Groups
    result.writeln();
    result.writeln('proxy-groups:');
    result.writeln('  - name: PROXY');
    result.writeln('    type: select');
    result.writeln('    proxies:');
    for (final name in selectedProxyNames) {
      result.writeln("      - ${yamlQuote(name)}");
    }
    result.writeln('  - name: GLOBAL');
    result.writeln('    type: select');
    result.writeln('    proxies:');
    result.writeln("      - 'PROXY'");
    for (final name in selectedProxyNames) {
      result.writeln("      - ${yamlQuote(name)}");
    }
    result.writeln('  - name: 自动选择');
    result.writeln('    type: url-test');
    result.writeln('    proxies:');
    for (final name in proxyNames) {
      result.writeln("      - ${yamlQuote(name)}");
    }
    result.writeln(
      '    url: ${yamlQuote(appSettings.latencyTestUrl)}',
    );
    result.writeln('    interval: 300');
    result.writeln('  - name: $_geoProxyGroupName');
    result.writeln('    type: select');
    result.writeln('    proxies:');
    for (final name in selectedProxyNames) {
      result.writeln("      - ${yamlQuote(name)}");
    }

    // Rules
    result.writeln();
    result.writeln('rules:');
    for (final rule in ClashConfigGenerator.buildForceProxyRulesFromSites(
      appSettings.forceProxySites,
    )) {
      result.writeln('  - ${yamlQuote(rule)}');
    }
    for (final host in _geoLookupHosts) {
      result.writeln("  - 'DOMAIN,$host,$_geoProxyGroupName'");
    }
    result.writeln("  - 'DOMAIN-SUFFIX,cn,DIRECT'");
    if (mmdbExists) {
      result.writeln("  - 'GEOIP,CN,DIRECT'");
      result.writeln("  - 'GEOIP,LAN,DIRECT,no-resolve'");
    }
    result.writeln("  - 'MATCH,PROXY'");

    return result.toString();
  }

  /// 写入配置
  Future<void> writeConfig(String configContent) async {
    if (_startupDisabledReason != null) {
      throw StateError(_startupDisabledReason!);
    }
    if (configPath.isEmpty) {
      throw StateError('Mihomo service is not initialized');
    }
    final file = File(configPath);
    final temp = File('$configPath.tmp');
    await temp.writeAsString(configContent);
    await temp.rename(file.path);
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
          notifyStatusChanged();
          _proxyService.clearSystemProxy();
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
        setRunning(true);
        resetHealthCheckFailures();
        log('✅ Mihomo API 就绪，耗时 ${startupWatch.elapsedMilliseconds}ms');

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

  // ── Clash API URL (redefined since base._apiUrl is library-private) ──

  String _apiUrl(String path) {
    final cleanPath = path.startsWith('/') ? path.substring(1) : path;
    return 'http://127.0.0.1:${settings.apiPort}/$cleanPath';
  }

  // ── Geo / exit country detection (Windows-specific) ──

  /// 测试延迟 (TCP 连接)
  Future<String?> detectExitCountryForProxy(
    String nodeName, {
    Duration timeout = const Duration(seconds: 7),
  }) async {
    if (!isRunning || nodeName.trim().isEmpty) return null;

    final groupName =
        settings.proxyMode == ProxyMode.global ? 'GLOBAL' : _geoProxyGroupName;
    final previousSelection = groupName == 'GLOBAL'
        ? await _currentProxyGroupSelection(groupName)
        : null;

    final switched = await _switchProxyGroup(groupName, nodeName);
    if (!switched) return null;

    try {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      return await _queryExitCountry(timeout: timeout);
    } finally {
      if (previousSelection != null &&
          previousSelection.isNotEmpty &&
          previousSelection != nodeName) {
        await _switchProxyGroup(groupName, previousSelection);
      }
    }
  }

  Future<String?> _currentProxyGroupSelection(String groupName) async {
    try {
      final client = apiClient;
      if (client == null) return null;
      final response = await client
          .get(
            Uri.parse(_apiUrl('/proxies/${Uri.encodeComponent(groupName)}')),
            headers: apiHeaders(),
          )
          .timeout(const Duration(seconds: 3));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        return decoded['now']?.toString();
      }
    } catch (_) {}
    return null;
  }

  Future<bool> _switchProxyGroup(String groupName, String nodeName) async {
    try {
      final client = apiClient;
      if (client == null) return false;
      final url = _apiUrl('/proxies/${Uri.encodeComponent(groupName)}');
      log('切换代理: group=$groupName, node=$nodeName');
      log('API URL: $url');

      final response = await client
          .put(
            Uri.parse(url),
            headers: apiHeaders(json: true),
            body: jsonEncode({'name': nodeName}),
          )
          .timeout(const Duration(seconds: 5));

      log('API 响应: ${response.statusCode} ${response.body}');

      if (response.statusCode == 200 || response.statusCode == 204) {
        log('✅ 代理切换成功: $nodeName');
        return true;
      }
      log('❌ 代理切换失败: HTTP ${response.statusCode}');
      return false;
    } catch (e) {
      log('❌ 切换代理异常: $e');
      return false;
    }
  }

  Future<String?> _queryExitCountry({required Duration timeout}) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 4)
      ..findProxy = (_) => 'PROXY 127.0.0.1:${settings.proxyPort}; DIRECT';
    try {
      for (final uri in const [
        'https://api.country.is/',
        'https://ipinfo.io/country',
        'https://ifconfig.co/country-iso',
      ]) {
        final country = await _queryExitCountryFrom(
          client,
          Uri.parse(uri),
          timeout,
        );
        if (country != null) return country;
      }
    } finally {
      client.close(force: true);
    }
    return null;
  }

  Future<String?> _queryExitCountryFrom(
    HttpClient client,
    Uri uri,
    Duration timeout,
  ) async {
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json,text/*');
      request.headers.set(HttpHeaders.userAgentHeader, 'SSRVPN/2.0');
      final response = await request.close().timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 500) {
        return null;
      }
      final body = await utf8.decodeStream(response).timeout(timeout);
      return _parseCountryCode(body);
    } catch (_) {
      return null;
    }
  }

  String? _parseCountryCode(String body) {
    final text = body.trim();
    if (text.isEmpty) return null;
    final plain = normalizeCountryCode(text);
    if (plain != null) return plain;

    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        for (final key in const ['country', 'countryCode', 'country_code']) {
          final value = decoded[key]?.toString();
          final code = normalizeCountryCode(value);
          if (code != null) return code;
        }
      }
    } catch (_) {}
    return null;
  }

  // ── Core path management ──

  void setCorePath(String path) => _corePath = path;
}
